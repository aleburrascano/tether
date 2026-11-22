"""Find the voices in a room as audio streams in, and keep clean audio of each one.

Every 0.5 s a voiceprint (ECAPA) is taken of the last 1.5 s. Windows that match a known voice are assigned
to it; three agreeing windows that match nobody start a new voice. A 0.5 s piece of audio is kept as
"clean" for a voice only if all three windows that cover it were confidently that voice, so pieces with
someone else talking in them are mostly left out. best_sample() re-ranks the kept pieces against the
voice's current voiceprint, so the sample gets better the longer the person talks.
"""
import threading
import time

import numpy as np

SR = 16000
HOP = SR // 2                 # 0.5 s
WIN = 3 * HOP                 # 1.5 s voiceprint window
KEEP = 180 * SR               # remember the last 3 minutes of audio
SAMPLE_HOPS = 6               # 3 s sample for the filter


class Voice:
    def __init__(self, vid, emb):
        self.id = vid
        self.cent = emb.copy()
        self.n = 1
        self.hops = {}            # hop index -> mean embedding of the 3 windows covering it
        self.last_heard = 0.0     # audio time (s) of the last window assigned to this voice

    def add(self, emb, w=1.0):
        c = self.cent * self.n + emb * w
        self.n += w
        self.cent = c / np.linalg.norm(c)

    def seconds(self):
        return len(self.hops) * HOP / SR


class VoiceFinder:
    def __init__(self, embed, t_assign=0.45, t_store=0.55, t_new=0.50, t_merge=0.65,
                 min_voiced=0.6, max_voices=6):
        self.embed = embed                       # fn(1.5 s float32 audio) -> unit-norm embedding
        self.t_assign, self.t_store, self.t_new, self.t_merge = t_assign, t_store, t_new, t_merge
        self.min_voiced, self.max_voices = min_voiced, max_voices
        self.lock = threading.Lock()
        self.audio = np.zeros(0, np.float32)
        self.offset = 0                          # absolute sample index of audio[0]
        self.total = 0                           # samples pushed so far
        self.done = 0                            # windows analysed so far
        self.voices, self.next_id = [], 1
        self.win = {}                            # window index -> (voice id or None, sim, emb)
        self.pending = []                        # unmatched windows waiting to become a new voice
        self.noise = None                        # running noise floor (frame RMS)

    # ------------------------------------------------------------------ input
    def push(self, x):
        with self.lock:
            self.audio = np.concatenate([self.audio, np.asarray(x, np.float32)])
            self.total += len(x)
            if len(self.audio) > KEEP:
                cut = len(self.audio) - KEEP
                self.audio, self.offset = self.audio[cut:], self.offset + cut

    def step(self):
        """Analyse every complete window not yet analysed. Returns how many were analysed."""
        n = 0
        while True:
            with self.lock:
                start = self.done * HOP
                if self.total < start + WIN:
                    return n
                w = self._get(start, start + WIN)
            self._window(self.done, w)
            self.done += 1
            n += 1

    def _get(self, a, b):
        a, b = max(a, self.offset), max(b, self.offset)
        return self.audio[a - self.offset:b - self.offset].copy()

    # -------------------------------------------------------------- analysis
    def _voiced(self, w):
        rms = np.sqrt((w[: len(w) // 320 * 320].reshape(-1, 320) ** 2).mean(1)) + 1e-6
        q = float(np.percentile(rms, 10))
        self.noise = q if self.noise is None else min(q, 0.98 * self.noise + 0.02 * q)
        thr = max(3.0 * self.noise, 0.003, 0.15 * float(np.percentile(rms, 95)))
        return float((rms > thr).mean())

    def _window(self, i, w):
        if len(w) < WIN or self._voiced(w) < self.min_voiced:
            self.win[i] = (None, 0.0, None)
            self.pending = []
            return
        e = self.embed(w)
        t = (i * HOP + WIN) / SR
        with self.lock:
            sims = [float(e @ v.cent) for v in self.voices]
            b = int(np.argmax(sims)) if sims else -1
            if b >= 0 and sims[b] >= self.t_assign:
                v = self.voices[b]
                v.last_heard = t
                if sims[b] >= self.t_store:
                    v.add(e, 0.5)
                self.win[i] = (v.id, sims[b], e)
                self.pending = []
            else:
                self.win[i] = (None, sims[b] if sims else 0.0, e)
                self.pending.append(i)
                self._maybe_new_voice(t)
            self._keep_clean_hop(i)
            self._maybe_merge()
            for k in [k for k in self.win if k < i - 400]:
                del self.win[k]

    def _maybe_new_voice(self, t):
        if len(self.pending) < 3 or len(self.voices) >= self.max_voices:
            return
        idx = self.pending[-3:]
        es = np.stack([self.win[k][2] for k in idx])
        m = es @ es.T
        if (m[np.triu_indices(3, 1)] < self.t_new).any():
            return
        c = es.mean(0)
        v = Voice(self.next_id, c / np.linalg.norm(c))
        self.next_id += 1
        v.last_heard = t
        self.voices.append(v)
        for k in idx:
            self.win[k] = (v.id, float(self.win[k][2] @ v.cent), self.win[k][2])
        self.pending = []
        for k in idx:
            self._keep_clean_hop(k)

    def _keep_clean_hop(self, i):
        """Hop i is covered by windows i-2, i-1, i. Keep it if all three are confidently the same voice."""
        cover = [self.win.get(k) for k in (i - 2, i - 1, i)]
        if any(c is None or c[0] is None or c[1] < self.t_store for c in cover):
            return
        if len({c[0] for c in cover}) != 1:
            return
        v = self._by_id(cover[0][0])
        if v is not None:
            e = sum(c[2] for c in cover)
            v.hops[i] = e / np.linalg.norm(e)

    def _maybe_merge(self):
        for a in range(len(self.voices)):
            for b in range(a + 1, len(self.voices)):
                va, vb = self.voices[a], self.voices[b]
                if float(va.cent @ vb.cent) >= self.t_merge:
                    keep, drop = (va, vb) if va.n >= vb.n else (vb, va)
                    keep.hops.update(drop.hops)
                    keep.add(drop.cent, drop.n)
                    keep.last_heard = max(keep.last_heard, drop.last_heard)
                    self.voices.remove(drop)
                    self.merged = getattr(self, "merged", {})
                    self.merged[drop.id] = keep.id
                    return

    def _by_id(self, vid):
        vid = getattr(self, "merged", {}).get(vid, vid)
        return next((v for v in self.voices if v.id == vid), None)

    # ---------------------------------------------------------------- output
    def resolve(self, vid):
        """A voice id that may have been merged into another one -> the id that now holds it."""
        with self.lock:
            v = self._by_id(vid)
            return v.id if v else None

    def best_sample(self, vid, hops=SAMPLE_HOPS, min_hops=2):
        """The voice's cleanest audio (up to 3 s, at least min_hops x 0.5 s), re-ranked against its current
        voiceprint. Returns (audio, mean score, hop ids) or None. Shorter than 3 s is fine: the filter repeats it,
        and it is replaced automatically as more of the voice is heard."""
        with self.lock:
            v = self._by_id(vid)
            if v is None:
                return None
            live = {h: e for h, e in v.hops.items() if h * HOP >= self.offset}
            if len(live) < min_hops:
                return None
            ranked = sorted(live, key=lambda h: -float(live[h] @ v.cent))[:hops]
            score = float(np.mean([live[h] @ v.cent for h in ranked]))
            parts = [self._get(h * HOP, (h + 1) * HOP) for h in sorted(ranked)]
            return np.concatenate(parts), score, tuple(sorted(ranked))

    def snapshot(self):
        with self.lock:
            now = self.total / SR
            return [{"id": v.id, "seconds": round(v.seconds(), 1),
                     "ready": len(v.hops) >= 2,                          # tappable
                     "full": v.seconds() >= SAMPLE_HOPS * HOP / SR,      # has a full 3 s clean sample
                     "speaking": now - v.last_heard < 1.2} for v in self.voices]


def ecapa_embedder(model_dir):
    """Load the SpeechBrain ECAPA voiceprint model; returns fn(audio) -> unit-norm numpy embedding."""
    import torch
    from speechbrain.inference.speaker import EncoderClassifier
    enc = EncoderClassifier.from_hparams("speechbrain/spkrec-ecapa-voxceleb", savedir=str(model_dir),
                                         run_opts={"device": "cpu"})

    @torch.no_grad()
    def embed(w):
        e = enc.encode_batch(torch.from_numpy(np.asarray(w, np.float32))[None]).squeeze().numpy()
        return e / (np.linalg.norm(e) + 1e-9)
    return embed


class Worker(threading.Thread):
    """Runs VoiceFinder.step() in the background so the audio path never waits on voiceprints."""
    def __init__(self, finder):
        super().__init__(daemon=True)
        self.finder, self.stop, self.ms = finder, threading.Event(), 0.0

    def run(self):
        while not self.stop.is_set():
            t = time.perf_counter()
            n = self.finder.step()
            if n:
                self.ms = (time.perf_counter() - t) * 1000 / n
            else:
                time.sleep(0.05)

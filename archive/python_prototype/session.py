"""One listening session: mic audio in -> (voices found in the background) -> filter -> audio out.

tap(voice_id) locks the filter onto that voice using the audio of them already heard (no waiting).
While locked, refine() runs every couple of seconds and swaps in a better sample when more clean audio
of the same person has come in, so it keeps getting better the longer they talk.
"""
import threading
import time
from pathlib import Path

from engine import Filter
from voices import SR, VoiceFinder, Worker, ecapa_embedder

ROOT = Path(__file__).resolve().parent
REFINE_EVERY = 2.0      # seconds of audio between refinement checks


class Session:
    def __init__(self, embed=None, filt=None, threaded=True):
        self.threaded = threaded          # False = offline test: voiceprints and refinement run inline
        self.embed = embed or ecapa_embedder(ROOT / "models" / "ecapa")
        self.filter = filt or Filter(ROOT / "models" / "realtse")
        self.reset()

    def reset(self):
        if getattr(self, "worker", None):
            self.worker.stop.set()
        self.finder = VoiceFinder(self.embed)
        self.worker = Worker(self.finder)
        if self.threaded:
            self.worker.start()
        self.filter.clear()
        self.filter.bypass = False
        self.focus, self.focus_hops, self.focus_score = None, (), 0.0
        self.refines, self.last_refine = 0, 0.0
        self.lock = threading.Lock()

    # -------------------------------------------------------------- audio
    def process(self, x):
        self.finder.push(x)
        if not self.threaded:
            self.finder.step()
        y = self.filter.process(x)
        t = self.finder.total / SR
        if self.focus is not None and t - self.last_refine >= REFINE_EVERY:
            self.last_refine = t
            if self.threaded:
                threading.Thread(target=self.refine, daemon=True).start()
            else:
                self.refine()
        return y

    # ------------------------------------------------------------ actions
    def tap(self, vid):
        got = self.finder.best_sample(vid)
        if got is None:
            return {"ok": False, "error": "not enough of this voice yet - let them talk a moment"}
        audio, score, hops = got
        with self.lock:
            self.filter.set_voice(audio, same_person=False)
            self.focus, self.focus_hops, self.focus_score = self.finder.resolve(vid), hops, score
            self.last_refine = self.finder.total / SR
        return {"ok": True, "seconds": round(len(audio) / SR, 1)}

    def refine(self):
        with self.lock:
            if self.focus is None:
                return
            vid = self.finder.resolve(self.focus)
            got = self.finder.best_sample(vid) if vid else None
            if got is None:
                return
            audio, score, hops = got
            more = len(hops) > len(self.focus_hops)
            if hops != self.focus_hops and (more or score > self.focus_score + 0.01):
                self.filter.set_voice(audio, same_person=True)
                self.focus, self.focus_hops, self.focus_score = vid, hops, score
                self.refines += 1

    def everyone(self, on):
        self.filter.bypass = bool(on)

    def release(self):
        with self.lock:
            self.filter.clear()
            self.focus, self.focus_hops = None, ()

    def state(self):
        f = self.finder.resolve(self.focus) if self.focus is not None else None
        return {"voices": self.finder.snapshot(), "focus": f, "everyone": self.filter.bypass,
                "sample_s": round(len(self.focus_hops) * 0.5, 1), "refines": self.refines,
                "filter_ms": round(self.filter.ms, 1), "voiceprint_ms": round(self.worker.ms, 1),
                "heard_s": round(self.finder.total / SR, 1)}

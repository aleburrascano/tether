"""The filter: REAL-TSE (causal, int8 ONNX) run through the voxlock streaming runtime.

Passthrough until a voice is set. set_voice(sample, same_person=True) swaps the voiceprint in place and keeps
the filter's memory, so refining the same person does not glitch; a new person starts a fresh stream.
"""
import threading
import time

import numpy as np
import voxlock
import voxlock.core

voxlock.core.GAIN = -1.0      # the REAL-TSE model returns the target at about -1x (stock VoxLock: -2x)


class Filter:
    def __init__(self, model_dir, threads=3):
        self.vl = voxlock.VoxLock(model_dir=str(model_dir), precision="int8", threads=threads)
        self.stream = None
        self.lock = threading.Lock()
        self.ms = 0.0                    # compute time of the last chunk
        self.bypass = False              # "hear everyone" while keeping the lock

    def set_voice(self, sample, same_person):
        sample = np.asarray(sample, np.float32)
        if len(sample) < voxlock.core.SAMPLE:          # tapped early: repeat what we have to the model's 3 s
            sample = np.tile(sample, int(np.ceil(voxlock.core.SAMPLE / max(1, len(sample)))))
        if same_person and self.stream is not None:
            voice = dict(zip(("enroll_n", "k", "v"),
                             self.vl.enroll.run(None, {"enroll": voxlock.core.fit_sample(sample)[None]})))
            with self.lock:
                self.stream.voice = voice
        else:
            st = self.vl.stream(sample)
            with self.lock:
                self.stream = st

    def clear(self):
        with self.lock:
            self.stream = None

    def process(self, x):
        """40 ms of mic audio in -> audio to play out (about the same length, 24 ms behind when filtering)."""
        t = time.perf_counter()
        with self.lock:
            st = self.stream
            y = st.push(x) if st is not None else x
            if st is not None and self.bypass:
                y = x
        self.ms = (time.perf_counter() - t) * 1000
        return y

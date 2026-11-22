"""Per-session report from the app's debug log (f80 metrics lines).
   usage: .venv/bin/python tools/report.py <debug_*.jsonl>
Classes per 80 ms frame (confident speaker-model answer, threshold 0.5): target only / both / other only / nobody.
- per person: speech time, median mic level when talking alone (louder ~ closer)
- for the selected person while the filter runs:
    kept   = filter output minus mic level when only they talk (0 dB = fully kept)
    leak   = filter output minus mic level when only others talk (very negative = others removed)
    muted  = share of frames the mute closed, per class (muting 'target' or 'both' = cutting your person)
"""
import json, sys, statistics as st
from collections import defaultdict
L = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
F = [x for x in L if x.get('type') == 'f80']
if not F: sys.exit('no f80 metrics in this log (older app version?)')
print(f'{len(F)} frames = {len(F)*0.08:.0f} s of audio')
solo = defaultdict(list)
for x in F:
    act = [i for i, v in enumerate(x['p']) if v > 0.5]
    if len(act) == 1: solo[act[0]].append(x['in'])
loud = max((st.median(v) for v in solo.values()), default=0)
print('\nperson  talking-alone  median level  vs loudest  (rough distance ratio if same voice volume)')
for s in sorted(solo):
    m = st.median(solo[s]); rel = m - loud
    print(f'  P{s+1}    {len(solo[s])*0.08:6.1f} s     {m:6.1f} dB    {rel:+5.1f} dB   ~x{10**(-rel/20):.1f} as far')
by = defaultdict(list)
for x in F:
    s = x['sel']
    if s < 0 or 'out' not in x: continue
    p = x['p']; t = p[s] > 0.5; o = any(v > 0.5 for i, v in enumerate(p) if i != s)
    c = 'both' if t and o else 'target' if t else 'other' if o else 'nobody'
    by[c].append(x)
print('\nwhile a person was selected and the filter ran:')
for c in ['target', 'both', 'other', 'nobody']:
    X = by[c]
    if not X: continue
    red = [x['out'] - x['in'] for x in X]
    mut = sum(1 for x in X if x.get('gate', 1) < 0.5) / len(X)
    print(f'  {c:7s} {len(X)*0.08:6.1f} s   filter out-in median {st.median(red):+6.1f} dB   muted {mut*100:4.0f}%')

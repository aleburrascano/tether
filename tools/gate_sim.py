"""Replay logged sessions through mute rules and count what you'd hear as problems.
   cuts  = moments the selected person was talking (confident, alone or with others) but the mute closed
   peeps = short open blips (<=0.4 s) inside stretches where only someone else talks
   leak  = share of 'someone else alone' time that was let through
"""
import json, sys, glob
def old_rule(P, s, extraction=True, hang=4):
    out=[]; 
    for f,p in enumerate(P):
        t=p[s]>0.5; o=any(v>0.5 for i,v in enumerate(p) if i!=s)
        if t: v=1
        elif o: v=0
        elif extraction: v=1
        else: v=1 if any(P[f-k][s]>0.5 for k in range(1,hang+1) if f-k>=0) else 0
        out.append(v)
    return out
def new_rule(P, s, on=0.5, off=0.3, other_run=2, short_hang=4, quiet_hang=8):
    out=[]; tgt=False; last=-10**9; run=0
    for f,p in enumerate(P):
        pt=p[s]; po=max(v for i,v in enumerate(p) if i!=s)
        if pt>on: tgt=True
        elif pt<off: tgt=False
        if tgt: last=f
        run = run+1 if po>0.5 and not tgt else 0
        if tgt: v=1
        elif po>0.5: v = 0 if (run>=other_run or f-last>short_hang) else 1
        else: v = 1 if f-last<=quiet_hang else 0
        out.append(v)
    return out
def score(P, s, G):
    cut=tt=0; leak=oo=0; peeps=0
    cls=[]
    for p in P:
        t=p[s]>0.5; o=any(v>0.5 for i,v in enumerate(p) if i!=s)
        cls.append('t' if t else 'o' if o else 'n')
    for c,g in zip(cls,G):
        if c=='t': tt+=1; cut+= g==0
        if c=='o': oo+=1; leak+= g==1
    # peeps: open runs of <=5 frames bordered by 'o' frames that are closed
    f=0
    while f<len(G):
        if G[f]==1 and cls[f] in 'on':
            e=f
            while e<len(G) and G[e]==1: e+=1
            if e-f<=5 and f>0 and cls[f-1]=='o' and G[f-1]==0 and e<len(G) and cls[e]=='o': peeps+=1
            f=e
        else: f+=1
    return cut,tt,leak,oo,peeps
tot={'old':[0]*5,'new':[0]*5}; dur=0
for fn in sys.argv[1:]:
    F=[json.loads(l) for l in open(fn) if '"f80"' in l]
    F=[x for x in F if x.get('type')=='f80']
    # segments with a constant selection
    segs={}
    for x in F:
        if x['sel']>=0: segs.setdefault(x['sel'],[]).append(x)
    for s,X in segs.items():
        X.sort(key=lambda x:x['f']); P=[x['p'] for x in X]; dur+=len(P)*0.08
        for name,rule in (('old',old_rule),('new',new_rule)):
            r=score(P,s,rule(P,s))
            tot[name]=[a+b for a,b in zip(tot[name],r)]
print(f'{dur:.0f} s of selected-person time across {len(sys.argv)-1} sessions')
for name in ('old','new'):
    cut,tt,leak,oo,peeps=tot[name]
    print(f'{name}: person cut {cut*0.08:5.1f} s of {tt*0.08:.0f} s ({100*cut/max(tt,1):.1f}%)  |  others let through {100*leak/max(oo,1):.1f}% of their solo time  |  peeps {peeps} ({peeps/(dur/60):.1f} per min)')

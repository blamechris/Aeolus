# ADR 0012's 2026-10-18 amendment: the review model of G's lower side (the gate waiter's wait with
# § 3's lane in it). Run from anywhere with `python3 scripts/gate-wait-model/event_run2.py`. Constants are
# WatchdogLimits' and the scheduler's at the amendment; WatchdogLimitsTests pins the two modelled
# windows, and these scripts count the histories the windows do not cover.
#
# The event model's worst case over firing heads, tails, turns in flight and phases, at N = 12.
import os, sys; sys.dont_write_bytecode = True; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from event import wait_of_W, RT_S
K, F = 34, 2
fire = [K] + [5] * F + [2] * (F * 3)
lat = [K]; rb = [K] + [3] * F; tb = fire; rev = [K] + [2] * (F * 3)
def gen(head, tail, n=30): return list(head) + [tail] * n
heads = {'whole firing': fire, 'firing, writes only': fire[1:], 'firing, restores only': fire[3:]}
tails = {'latched': lat, 'read-back': rb, 'take-back': tb, 'revoke-only': rev}
for N in (12,):
    worst = (0, None)
    for hn, h in heads.items():
        for tn, tl in tails.items():
            for second in (None, lat):
                hist = [h] + ([second] if second else []) + [tl] * 30
                for inflight in (('snap', 64), ('x', 5), ('x', 34)):
                    for p in range(-60, 120, 1):
                        w = wait_of_W(N, K, hist, p, inflight)
                        if w > worst[0]: worst = (w, (hn, tn, second is not None, inflight, p))
    print(N, worst[0], round(worst[0] * RT_S, 3), worst[1])

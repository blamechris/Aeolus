# ADR 0012's 2026-10-18 amendment: the review model of G's lower side (the gate waiter's wait with
# § 3's lane in it). Run from anywhere with `python3 scripts/gate-wait-model/event_search.py`. Constants are
# WatchdogLimits' and the scheduler's at the amendment; WatchdogLimitsTests pins the two modelled
# windows, and these scripts count the histories the windows do not cover.
#
# A wider search of the event model at N = 12: histories with no firing head, one or two latched
# cycles before the tail, and phases from -200 to 199 round trips. Its worst is 611 round trips.
import os, sys; sys.dont_write_bytecode = True; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from event import wait_of_W, RT_S
K, F = 34, 2
fire = [K] + [5] * F + [2] * (F * 3)
lat = [K]; rb = [K] + [3] * F; tb = fire; rev = [K] + [2] * (F * 3)
heads = {'fire': [fire], 'rb': [rb], 'none': []}
tails = {'lat': lat, 'rb': rb, 'tb': tb, 'rev': rev}
worst = (0, None)
for hn, h in heads.items():
    for tn, tl in tails.items():
        for mid in ([], [lat], [lat, lat]):
            hist = h + mid + [tl] * 30
            if not hist: continue
            for inflight in (('snap', 64), ('x', 5), ('x', 34), ('x', 64)):
                for p in range(-200, 200):
                    w = wait_of_W(12, K, hist, p, inflight)
                    if w > worst[0]: worst = (w, (hn, tn, len(mid), inflight, p))
print(worst[0], round(worst[0] * RT_S, 3), worst[1])

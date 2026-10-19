# ADR 0012's 2026-10-18 amendment: the review model of G's lower side (the gate waiter's wait with
# § 3's lane in it). Run from anywhere with `python3 scripts/gate-wait-model/event_run.py`. Constants are
# WatchdogLimits' and the scheduler's at the amendment; WatchdogLimitsTests pins the two modelled
# windows, and these scripts count the histories the windows do not cover.
#
# The event model over the named histories, at several N.
import os, sys; sys.dont_write_bytecode = True; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from event import wait_of_W, RT_S
K, F = 34, 2
fire = [K] + [5] * F + [2] * (F * 3)
lat = [K]; rb = [K] + [3] * F; tb = fire; rev = [K] + [2] * (F * 3)
def gen(head, tail, n=30): return list(head) + [tail] * n
cases = {
    'fire, latched...': gen([fire], lat),
    'read-back...': gen([rb], rb),
    'fire, release, read-back...': gen([fire, lat], rb),
    'fire, take-back x2, latched...': gen([fire, tb, tb], lat),
    'fire, take-back, revoke-only...': gen([fire, tb], rev),
    'take-back every cycle': gen([fire], tb),
}
for N in (12, 13, 16, 20):
    print('N =', N)
    for name, h in cases.items():
        best = max(wait_of_W(N, K, h, p) for p in range(-60, 120, 2))
        print(f'   {name:34s} {best:7.1f} RT {best * RT_S:6.3f} s')

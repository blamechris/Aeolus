# ADR 0012's 2026-10-18 amendment: the review model of G's lower side (the gate waiter's wait with
# § 3's lane in it). Run from anywhere with `python3 scripts/gate-wait-model/starts2.py`. Constants are
# WatchdogLimits' and the scheduler's at the amendment; WatchdogLimitsTests pins the two modelled
# windows, and these scripts count the histories the windows do not cover.
#
# The same count over histories whose latched cycles revoke with or without restores refused.
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from starts import wait, gen, fire, lat, rb, tb, K, F, RT
rev_refused = K + F * 3 * 2
rev_accepted = K + F * 2
cases = {
    'fire, revoke-only(refused) every cycle': gen([fire], rev_refused),
    'fire, revoke-only(accepted) every cycle': gen([fire], rev_accepted),
    'fire, take-back, revoke-only(refused)...': gen([fire, tb], rev_refused),
    'fire, take-back x2, release, read-back...': gen([fire, tb, tb, lat], rb),
}
for N in (10, 11, 12):
    print('N =', N)
    for name, h in cases.items():
        best = max(wait(N, h, d * RT) for d in range(0, 65))
        print(f'   {name:44s} {best:5d} RT {best * RT / 1e6:6.3f} s')

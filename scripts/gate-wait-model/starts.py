# ADR 0012's 2026-10-18 amendment: the review model of G's lower side (the gate waiter's wait with
# § 3's lane in it). Run from anywhere with `python3 scripts/gate-wait-model/starts.py`. Constants are
# WatchdogLimits' and the scheduler's at the amendment; WatchdogLimitsTests pins the two modelled
# windows, and these scripts count the histories the windows do not cover.
#
# The correct count for mixed histories: the firing head once, cycle starts spaced by the
# interval plus the cycle's own round trips. Gives 817-831 at N = 12, and 919 for a take-back
# every cycle.
# A tighter count than either window: the queue, plus the lane RT of every § 3 cycle that starts
# before the waiter is admitted, with cycle i+1 starting no sooner than 1 s + c_i RT after cycle i
# (ThermalSupervisor.run: cycle(), then sleep(until: now + interval)). The head cycle may have
# queued its first turn up to one 64-RT turn in flight before the waiter arrived.
import itertools
RT = 11_453; INTERVAL = 1_000_000; K = 34; F = 2
def queue(N):
    return 64 + K + 5 * max(N - 2, 0) + 64 * (max(N - 1, 0) // 2 + 1) - min(5, K)
fire = K + F * 5 + F * 3 * 2; lat = K; rb = K + F * 3; tb = fire; rev = K + F * 3 * 2
def wait(N, hist, delta):
    q = queue(N)
    w = q
    for _ in range(200):
        t = -delta; tot = 0
        for c in hist:
            if t >= RT * w: break
            tot += c; t += INTERVAL + RT * c
        nw = q + tot
        if nw == w: return w
        w = nw
    return w
def gen(head, tail, n=40): return list(head) + [tail] * n
cases = {
    'fire, latched...': gen([fire], lat),
    'read-back...': gen([rb], rb),
    'fire, release, read-back...': gen([fire, lat], rb),
    'fire, take-back, latched...': gen([fire, tb], lat),
    'fire, take-back x2, latched...': gen([fire, tb, tb], lat),
    'take-back every cycle (not reachable?)': gen([fire], tb),
    'read-back x2, fire, latched...': gen([rb, rb, fire], lat),
    'read-back x5, fire, latched...': gen([rb] * 5 + [fire], lat),
}
if __name__ == '__main__':
    for N in (12, 13):
        print('N =', N)
        for name, h in cases.items():
            best = max(wait(N, h, d * RT) for d in range(0, 65))
            print(f'   {name:40s} {best:5d} RT {best * RT / 1e6:6.3f} s')

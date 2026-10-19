# ADR 0012's 2026-10-18 amendment: the review model of G's lower side (the gate waiter's wait with
# § 3's lane in it). Run from anywhere with `python3 scripts/gate-wait-model/closed_mixed.py`. Constants are
# WatchdogLimits' and the scheduler's at the amendment; WatchdogLimitsTests pins the two modelled
# windows, and these scripts count the histories the windows do not cover.
#
# Closed form: L9 and L10 re-derived, then the closed form's fixed point over mixed histories.
# Independent re-derivation of L9/L10 from WatchdogLimits.swift at c2eb163, plus the closed form's
# own fixed point applied to mixed § 3 histories. Integer microseconds, as the Swift does.
RT = 11_453; INTERVAL = 1_000_000; SLOP = 100_000; D = 5_000_000
TURN = 64; QUOTA = 2; ATT = 3; WRITE = 5; FANRESTORE = 2; MODE = 3

def allowance(K, F):
    turns = 1 + F + F * ATT
    return TURN * turns + K + F * WRITE + F * ATT * FANRESTORE
def writes(F): return F * WRITE + F * ATT * FANRESTORE
def dcycle(K, F, wrt=RT):
    w = writes(F); r = allowance(K, F) - w
    return INTERVAL + SLOP + D + RT * r + wrt * w
def queue(N, K):
    return TURN + K + 5 * max(N - 2, 0) + TURN * (max(N - 1, 0) // QUOTA + 1) - min(5, K)
def ceil_div(a, b): return -(-a // b)
def window(base, per, K):
    P = INTERVAL + RT * K
    w = base
    for _ in range(1000):
        nw = base + ceil_div(RT * w, P) * per
        if nw == w: return w
        w = nw
    raise RuntimeError
def gate(N, K, F):
    q = queue(N, K)
    a = window(q + K + writes(F), K, K)
    b = window(q, K + F * MODE, K)
    return max(a, b), a, b

K, F = 34, 2
A = allowance(K, F)
print('L9 allowance', A, 'RT; D_cycle needs', dcycle(K, F) / 1e6, 's; at 50 ms writes', dcycle(K, F, 50_000) / 1e6)
# break-even write RT
w = writes(F); r = A - w
be = (15_000_000 - INTERVAL - SLOP - D - RT * r) / w
print('  break-even write RT', be / 1000, 'ms; F=3', allowance(K, 3), dcycle(K, 3) / 1e6)
for N in (11, 12, 13):
    g, a, b = gate(N, K, F)
    print(f'L10 N={N}: queue {queue(N, K)} a {a} b {b} -> {g} RT {g * RT / 1e6:.6f} s')

# Mixed histories, in the closed form's own model: the queue, plus every cycle that can start in
# the wait at one per (interval + K RT). Convention A (the PR's window (a)): the first cycle is
# extra, then ceil(w/P) cycles. Convention B: ceil(w/P) cycles in all, the first of them the
# history's head.
def mixed(N, hist_head, tail, conv):
    q = queue(N, K); P = INTERVAL + RT * K
    def cost(n):  # lane RT for n cycles of the history
        h = list(hist_head)
        s = 0
        for i in range(n):
            s += h[i] if i < len(h) else tail
        return s
    w = q + (hist_head[0] if conv == 'A' else 0)
    for _ in range(1000):
        c = ceil_div(RT * w, P)
        nw = q + (hist_head[0] + cost_after(hist_head, tail, c) if conv == 'A' else cost(c))
        if nw == w: return w
        w = nw
    raise RuntimeError
def cost_after(head, tail, c):
    rest = list(head[1:]); s = 0
    for i in range(c):
        s += rest[i] if i < len(rest) else tail
    return s

fire = K + writes(F)            # 56: read, two bridge jobs, six refused restores
latched = K                     # 34
readback = K + F * MODE         # 40
takeback = K + writes(F)        # 56: a latched cycle that bridges a late engagement and revokes
revoke_only = K + F * ATT * FANRESTORE  # 46: a latched cycle revoking a surviving lease
cases = {
    '(a) fire, latched...': ([fire], latched),
    '(b) read-back...': ([readback], readback),
    'fire, release, read-back...': ([fire, latched], readback),
    'fire, take-back, latched...': ([fire, takeback], latched),
    'fire, take-back x2, latched...': ([fire, takeback, takeback], latched),
    'fire, revoke-only, latched...': ([fire, revoke_only], latched),
    'read-back x2, fire, latched...': ([readback, readback, fire], latched),
}
for N in (10, 11, 12):
    print(f'N={N}')
    for name, (head, tail) in cases.items():
        for conv in ('A', 'B'):
            w = mixed(N, head, tail, conv)
            print(f'   {conv} {name:34s} {w:5d} RT {w * RT / 1e6:6.3f} s {"> G" if w * RT >= 10_000_000 else ""}')

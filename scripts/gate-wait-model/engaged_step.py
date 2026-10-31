# ADR 0014's P1′ amendment asks #465 to re-run ADR 0012's G at N = 12 once the engaged step at rest
# takes eight round trips (WatchdogLimits.engagedStepRoundTrips). Run from anywhere with
# `python3 scripts/gate-wait-model/engaged_step.py`. It re-counts the supervisor queue, the two
# modelled windows WatchdogLimitsTests pins, the histories starts.py and starts2.py count, and the
# event model event_search.py searches, under three models of the readers ahead of the waiter:
#
#   five   every reader at five round trips: ADR 0012's figures, reproduced as a check;
#   eight  every reader at eight, the engaged step: readerTurnRoundTrips taken for every reader;
#   once   at most one engaged step per fan at eight, every other reader at five: what
#          WatchdogLimits.supervisorQueueRoundTrips counts on this branch.
#
# Integer microseconds, as the Swift does. Constants are WatchdogLimits' and the scheduler's.
import collections
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from starts import gen  # noqa: E402

RT = 11_453; INTERVAL = 1_000_000; G = 10_000_000
TURN = 64; QUOTA = 2; ATT = 3; WRITE = 5; FANRESTORE = 2; MODE = 3; ENGAGED = 8
K, F = 34, 2


def turns(n, model):
    """The round trips of n queued readers' turns."""
    if model == 'five':
        return 5 * n
    if model == 'eight':
        return ENGAGED * n
    long = min(n, F)
    return ENGAGED * long + max(MODE, WRITE) * (n - long)


def queue(N, model):
    """The longer of the last reader's wait and the grant path's read's, as the Swift has it."""
    readers = max(N - 2, 0)
    forced = TURN * (max(N - 1, 0) // QUOTA + 1)
    last = TURN + K + turns(readers - 1, model) + forced if readers > 0 else 0
    return max(last, TURN + turns(readers, model) + forced)


def window(base, per):
    period = INTERVAL + RT * K
    w = base
    for _ in range(1000):
        nw = base + -(-RT * w // period) * per
        if nw == w:
            return w
        w = nw
    raise RuntimeError('unsettled')


def modelled(N, model):
    q = queue(N, model)
    writes = F * WRITE + F * ATT * FANRESTORE
    return q, max(window(q + K + writes, K), window(q, K + F * MODE))


def history(N, hist, delta, model):
    """starts.py's count: the firing head once, cycle starts spaced by the interval plus the
    cycle's own round trips."""
    q = queue(N, model)
    w = q
    for _ in range(200):
        t = -delta; tot = 0
        for c in hist:
            if t >= RT * w:
                break
            tot += c; t += INTERVAL + RT * c
        nw = q + tot
        if nw == w:
            return w
        w = nw
    return w


fire = K + F * 5 + F * 3 * 2; lat = K; rb = K + F * 3; tb = fire
closed = {
    'fire, latched...': gen([fire], lat),
    'read-back...': gen([rb], rb),
    'fire, release, read-back...': gen([fire, lat], rb),
    'fire, take-back, latched...': gen([fire, tb], lat),
    'fire, take-back x2, latched...': gen([fire, tb, tb], lat),
    'read-back x2, fire, latched...': gen([rb, rb, fire], lat),
    'read-back x5, fire, latched...': gen([rb] * 5 + [fire], lat),
}
opened = {
    'take-back every cycle': gen([fire], tb),
    'fire, revoke-only(refused) every cycle': gen([fire], K + F * 3 * 2),
    'fire, revoke-only(accepted) every cycle': gen([fire], K + F * 2),
    'fire, take-back, revoke-only(refused)...': gen([fire, tb], K + F * 3 * 2),
    'fire, take-back x2, release, read-back...': gen([fire, tb, tb, lat], rb),
}


def event_wait(hist, phase, model, inflight):
    """event.py's model, with the readers ahead of the waiter from `turns`."""
    readers = max(12 - 3, 0)
    ahead = [ENGAGED] * min(readers, F) if model == 'once' else []
    each = {'five': 5, 'eight': ENGAGED, 'once': 5}[model]
    ahead += [each] * (readers - len(ahead))
    sup = collections.deque([('grant', K)] + [(('r', i), t) for i, t in enumerate(ahead)]
                            + [('W', ENGAGED if model == 'eight' else 5)])
    snap = collections.deque([('snap', TURN)]); lane = collections.deque()
    over = 0; cyc = 0; ti = 0; s3_next = phase; s3_waiting = False
    interval = 1.0 / (RT / 1e6)

    def nxt():
        nonlocal over
        if lane:
            return lane.popleft()
        if not snap:
            over = 0; return sup.popleft() if sup else None
        if sup and over < QUOTA:
            over += 1; return sup.popleft()
        over = 0; return snap.popleft()
    cur = inflight; end = cur[1]
    while True:
        if not s3_waiting and ti == 0 and cyc < len(hist) and s3_next <= end:
            lane.append(('s3', hist[cyc][0])); s3_waiting = True
        t = end; owner, length = cur
        if owner == 'W':
            return t - length
        if owner == 'snap':
            snap.append(('snap', TURN))
        n = nxt()
        if owner == 's3':
            s3_waiting = False; ti += 1
            if ti == len(hist[cyc]):
                ti = 0; cyc += 1; s3_next = t + interval
            else:
                lane.append(('s3', hist[cyc][ti])); s3_waiting = True
        if n is None:
            n = nxt()
        cur = n; end = t + n[1]


def event_worst(model):
    efire = [K] + [5] * F + [2] * (F * 3)
    elat = [K]; erb = [K] + [3] * F; erev = [K] + [2] * (F * 3)
    worst = 0
    for head in ([efire], [erb], []):
        for tail in (elat, erb, efire, erev):
            for mid in ([], [elat], [elat, elat]):
                hist = head + mid + [tail] * 30
                for inflight in (('snap', 64), ('x', 5), ('x', ENGAGED), ('x', 34), ('x', 64)):
                    for p in range(-200, 200):
                        worst = max(worst, event_wait(hist, p, model, inflight))
    return worst


def fmt(rt):
    return f'{rt:5.0f} RT {rt * RT / 1e6:6.3f} s{"  over G" if rt * RT >= G else ""}'


if __name__ == '__main__':
    for model in ('five', 'eight', 'once'):
        print(f'## readers: {model}')
        for N in (12, 13):
            q, m = modelled(N, model)
            print(f'  N = {N}: queue {q}, modelled {fmt(m)}, slot (+{ENGAGED}) {fmt(m + ENGAGED)}')
        for name, cases in (('closed', closed), ('open', opened)):
            for case, hist in cases.items():
                best = max(history(12, hist, d * RT, model) for d in range(0, 65))
                print(f'  N = 12 {name:6s} {case:44s} {fmt(best)}')
        print(f'  N = 12 event model worst {fmt(event_worst(model))}')
    # ADR 0012's figures, reproduced: the 'five' model is the committed scripts' arithmetic.
    assert modelled(12, 'five') == (527, 821)
    assert modelled(12, 'once') == (533, 827)

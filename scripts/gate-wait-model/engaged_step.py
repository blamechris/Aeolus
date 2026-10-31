# ADR 0014's P1′ amendment asks #465 to re-run ADR 0012's G at N = 12 with the engaged step: the
# step that reads back `1`, nine round trips when it raises its fan to the floor with `F<n>Tg`'s key
# info not cached (WatchdogLimits.engagedStepRoundTrips; ADR 0012's 2026-10-31 amendment). Run from
# anywhere with `python3 scripts/gate-wait-model/engaged_step.py`. Every figure that amendment, and
# ADR 0014's b2 amendment as settled by P1′, cite is printed here, and the ones the ADRs lean on are
# asserted. On Mac16,5 (K = 34, F = 2), at N = 12:
#
#   1. the supervisor queue, the two modelled windows WatchdogLimitsTests pins, and the slot;
#   2. the histories starts.py and starts2.py count, and the event model event_search.py searches,
#      under three models of the readers ahead of the waiter:
#        five   every reader at five round trips: ADR 0012's figures, reproduced as a check;
#        every  every reader at the engaged step, readerTurnRoundTrips taken for every reader: at
#               eight, the length ADR 0012's 2026-10-31 amendment quotes it at, and at nine;
#        once   at most one engaged step per fan, every other reader at five: what
#               WatchdogLimits.supervisorQueueRoundTrips counts on this branch;
#   3. the refused-revocation family's fully refused form, which the abandoned-fan refusal bounds:
#      at most F fully refused revocations after one firing, each at the full F-fan cost; and how
#      many full-cost revocations its member over G needs;
#   4. what passing G costs in the open families: ADR 0014's examination hold (three slots and
#      stepWait, against examinationWait and its margin) and an apply's per-fan time (stepWait and
#      five slots, against applyPerFan);
#   5. the write round trip at which G's modelled slot breaks, before the engaged step and with it,
#      and the one past which the engaged step outgrows the 64-round-trip turn D_cycle counts in
#      flight ahead of each of § 3's turns, against D_cycle's own break-even. Both are in D_cycle's
#      model: reads at the measured worst round trip, writes at W. The engaged step and D_cycle
#      taken at one latency are printed apart, because that is another model and its figures do
#      not compare with the first's.
#
# Integer microseconds, as the Swift does. Constants are WatchdogLimits', the scheduler's and
# FanExaminationGate's.
import collections
import os
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from starts import gen  # noqa: E402

RT = 11_453; INTERVAL = 1_000_000; G = 10_000_000
TURN = 64; QUOTA = 2; ATT = 3; WRITE = 5; FANRESTORE = 2; MODE = 3; ENGAGED = 9
K, F = 34, 2
STEP_WAIT = 1_000_000; EXAMINATION_WAIT = 32_000_000; MARGIN = 1_000_000; APPLY_PER_FAN = 52_000_000


def turns(n, model, eng=ENGAGED):
    """The round trips of n queued readers' turns."""
    if model == 'five':
        return 5 * n
    if model == 'every':
        return eng * n
    long = min(n, F)
    return eng * long + max(MODE, WRITE) * (n - long)


def queue(N, model, eng=ENGAGED):
    """The longer of the last reader's wait and the grant path's read's, as the Swift has it."""
    readers = max(N - 2, 0)
    forced = TURN * (max(N - 1, 0) // QUOTA + 1)
    last = TURN + K + turns(readers - 1, model, eng) + forced if readers > 0 else 0
    return max(last, TURN + turns(readers, model, eng) + forced)


def window(base, per):
    period = INTERVAL + RT * K
    w = base
    for _ in range(1000):
        nw = base + -(-RT * w // period) * per
        if nw == w:
            return w
        w = nw
    raise RuntimeError('unsettled')


def modelled(N, model, eng=ENGAGED):
    q = queue(N, model, eng)
    writes = F * WRITE + F * ATT * FANRESTORE
    return q, max(window(q + K + writes, K), window(q, K + F * MODE))


def history(N, hist, delta, model, eng=ENGAGED):
    """starts.py's count: the firing head once, cycle starts spaced by the interval plus the
    cycle's own round trips."""
    q = queue(N, model, eng)
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


def worst(hist, model, eng=ENGAGED):
    return max(history(12, hist, d * RT, model, eng) for d in range(0, 65))


fire = K + F * 5 + F * 3 * 2; lat = K; rb = K + F * 3; tb = fire
rev = K + F * ATT * 2; rev1 = K + 1 * ATT * 2
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
    'fire, revoke-only(refused) every cycle': gen([fire], rev),
    'fire, revoke-only(accepted) every cycle': gen([fire], K + F * 2),
    'fire, take-back, revoke-only(refused)...': gen([fire, tb], rev),
    'fire, take-back x2, release, read-back...': gen([fire, tb, tb, lat], rb),
}
# The refused-revocation family's fully refused form. A fan whose revocation is refused on every
# attempt lands in restoreAbandoned, and the grant refuses such a fan after its last suspension
# point until § 7's read-back, so at most F fully refused revocations follow one firing. Each is
# counted at the full F-fan cost, which over-counts one that abandons a single fan.
bounded = {
    'fire, 2 refused revocations, latched...': gen([fire, rev, rev], lat),
    'fire, take-back, 2 refused revocations, latched...': gen([fire, tb, rev, rev], lat),
    'fire, take-back x2, 2 refused revocations, latched...': gen([fire, tb, tb, rev, rev], lat),
    'fire, take-back, 2 one-fan refusals, latched...': gen([fire, tb, rev1, rev1], lat),
}


def event_wait(hist, phase, model, inflight, eng=ENGAGED):
    """event.py's model, with the readers ahead of the waiter from `turns`."""
    readers = max(12 - 3, 0)
    ahead = [eng] * min(readers, F) if model == 'once' else []
    each = {'five': 5, 'every': eng, 'once': 5}[model]
    ahead += [each] * (readers - len(ahead))
    sup = collections.deque([('grant', K)] + [(('r', i), t) for i, t in enumerate(ahead)]
                            + [('W', eng if model == 'every' else 5)])
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


def event_worst(model, eng=ENGAGED):
    efire = [K] + [5] * F + [2] * (F * 3)
    elat = [K]; erb = [K] + [3] * F; erev = [K] + [2] * (F * 3)
    result = 0
    for head in ([efire], [erb], []):
        for tail in (elat, erb, efire, erev):
            for mid in ([], [elat], [elat, elat]):
                hist = head + mid + [tail] * 30
                for inflight in (('snap', 64), ('x', 5), ('x', eng), ('x', 34), ('x', 64)):
                    for p in range(-200, 200):
                        result = max(result, event_wait(hist, p, model, inflight, eng))
    return result


# Section 5: G's modelled slot with writes at W µs and reads at RT, from SMCWriteTurns' turn shapes.
# The engaged step that raises is six reads and two writes warm, seven and two cold (its target's
# read takes the key info). Under `once` every other reader is not an engagement step, since one
# engagement per fan at a time puts each fan's steps in its own slot: the longer of the Swift's five
# at the read worst, a machine-wide restore (three writes) and a command (a write and two reads). §
# 3's firing cycle is its read, a bridge job per fan (a command and a two-write `.fan` restore), and
# attemptBudget two-write refused restores per fan.
def slot_with_writes(W, eng_reads=7, eng_writes=2):
    eng = eng_reads * RT + eng_writes * W
    other = max(5 * RT, 3 * W, W + 2 * RT)
    readers = 12 - 2; forced = TURN * RT * ((12 - 1) // QUOTA + 1)
    def t(n):
        long = min(n, F); return long * eng + (n - long) * other
    q = max(TURN * RT + K * RT + t(readers - 1) + forced, TURN * RT + t(readers) + forced)
    return max(_window_us(q + K * RT + F * (3 * W + 2 * RT) + F * ATT * 2 * W, K * RT),
               _window_us(q, K * RT + F * MODE * RT)) + eng


def slot_before_the_engaged_step(W):
    """ADR 0012's model before #465: every reader at the longest write turn, a first step on the
    force-key path (three reads and two writes), a machine-wide restore, or five reads."""
    other = max(5 * RT, 3 * W, 2 * W + 3 * RT)
    readers = 12 - 2; forced = TURN * RT * ((12 - 1) // QUOTA + 1)
    q = max(TURN * RT + K * RT + (readers - 1) * other + forced,
            TURN * RT + readers * other + forced)
    return max(_window_us(q + K * RT + F * (3 * W + 2 * RT) + F * ATT * 2 * W, K * RT),
               _window_us(q, K * RT + F * MODE * RT)) + other


def _window_us(base, per):
    period = INTERVAL + K * RT
    w = base
    for _ in range(1000):
        nw = base + -(-w // period) * per
        if nw == w:
            return w
        w = nw
    raise RuntimeError('unsettled')


def break_even(slot):
    lo, hi = RT, 50_000
    while hi - lo > 10:
        mid = (lo + hi) // 2
        if slot(mid) < G:
            lo = mid
        else:
            hi = mid
    return lo


CYCLE_ROOM = 15_000_000 - INTERVAL - 100_000 - 5_000_000  # D_cycle less the interval, slop and D


def cycle_round_trips():
    """§ 3's firing cycle with every restore refused, as D_cycle's allowance counts it: its reads
    (the 64-key slices and the curated read) and its writes."""
    return TURN * (1 + F + F * ATT) + K, F * WRITE + F * ATT * FANRESTORE


def cycle_break_even():
    """D_cycle's: 15 s against the interval, slop, D, § 3's reads at RT and its writes at W."""
    reads, writes = cycle_round_trips()
    return (CYCLE_ROOM - reads * RT) / writes


def cycle_uniform_break_even():
    """D_cycle's allowance with every round trip, reads and writes, at one latency. The other
    model: it is the one a figure like TURN * RT / ENGAGED (nine round trips at one latency) is
    in, and it breaks D_cycle far sooner than the first model does."""
    return CYCLE_ROOM / sum(cycle_round_trips())


def engaged_step_break_even(reads=7, writes=2):
    """The write round trip past which the engaged step outgrows the TURN read round trips
    D_cycle counts in flight ahead of each of § 3's turns, in D_cycle's model: reads at RT, writes
    at W. The step that raises its fan is seven reads and two writes cold, six and two warm."""
    return (TURN * RT - reads * RT) / writes


def fmt(rt):
    return f'{rt:5.0f} RT {rt * RT / 1e6:6.3f} s{"  over G" if rt * RT >= G else ""}'


def s(us):
    return f'{us / 1e6:.2f} s'


if __name__ == '__main__':
    print('# 1 and 2: the queue, the modelled cases, the histories and the event model, N = 12')
    for model, eng in (('five', ENGAGED), ('every', 8), ('every', ENGAGED), ('once', ENGAGED)):
        label = model if model == 'five' else f'{model}, engaged step at {eng}'
        print(f'## readers: {label}')
        turn = 5 if model == 'five' else eng
        for N in (12, 13):
            q, m = modelled(N, model, eng)
            print(f'  N = {N}: queue {q}, modelled {fmt(m)}, slot (+{turn}) {fmt(m + turn)}')
        for name, cases in (('closed', closed), ('open', opened)):
            for case, hist in cases.items():
                print(f'  N = 12 {name:6s} {case:44s} {fmt(worst(hist, model, eng))}')
        print(f'  N = 12 event model worst {fmt(event_worst(model, eng))}')

    print('# 3: the refused-revocation family, bounded and open (once, engaged step at 9)')
    for case, hist in bounded.items():
        w = worst(hist, 'once')
        print(f'  {case:56s} wait {fmt(w)}, slot {fmt(w + ENGAGED)}')
    for k in range(1, 7):
        w = worst(gen([fire, tb] + [rev] * k, lat), 'once')
        print(f'  fire, take-back, {k} full-cost refused revocation(s), latched: wait {fmt(w)}')

    print('# 4: what passing G costs in the open families (once at 9; five, before it, at 5)')
    for model, turn in (('once', ENGAGED), ('five', 5)):
        for case in ('fire, take-back, revoke-only(refused)...', 'take-back every cycle'):
            slot = (worst(opened[case], model) + turn) * RT
            hold = 3 * slot + STEP_WAIT
            apply = 5 * slot + STEP_WAIT
            wait = (f'margin spent {s(hold - EXAMINATION_WAIT + MARGIN)}' if hold <= EXAMINATION_WAIT
                    else f'outlasts it by {s(hold - EXAMINATION_WAIT)}')
            print(f'  {model:4s} {case:44s} slot {s(slot)}; three slots and stepWait {s(hold)} '
                  f'against examinationWait {s(EXAMINATION_WAIT)} ({wait}); stepWait and five '
                  f'slots {s(apply)} against applyPerFan {s(APPLY_PER_FAN)}')

    print('# 5: write round trips')
    print(f'  G\'s modelled slot breaks at a write round trip of about '
          f'{break_even(slot_with_writes) / 1000:.2f} ms with the engaged step at nine, '
          f'{break_even(lambda w: slot_with_writes(w, 6, 2)) / 1000:.2f} ms at eight, and '
          f'{break_even(slot_before_the_engaged_step) / 1000:.2f} ms before it')
    print(f'  with reads at {RT / 1000:.3f} ms and writes at W, D_cycle\'s own writes break even '
          f'at {cycle_break_even() / 1000:.2f} ms, and the engaged step outgrows the {TURN}-round-'
          f'trip turn in flight only past a W of {engaged_step_break_even() / 1000:.1f} ms cold '
          f'(seven reads, two writes), {engaged_step_break_even(6, 2) / 1000:.1f} ms warm')
    print(f'  at one latency, another model: the engaged step fits that turn while a round trip is '
          f'at most {TURN * RT / ENGAGED / 1000:.1f} ms (nine), {TURN * RT / 8 / 1000:.1f} ms '
          f'(eight), and D_cycle itself breaks at {cycle_uniform_break_even() / 1000:.2f} ms')

    # ADR 0012's figures, reproduced: the 'five' model is the committed scripts' arithmetic.
    assert modelled(12, 'five') == (527, 821)
    # The shipped count, and G's reach.
    assert modelled(12, 'once') == (535, 829)
    assert modelled(13, 'once')[1] == 932
    # Every reader at eight: four of the closed histories pass G (874-892).
    over = sorted(worst(h, 'every', 8) for h in closed.values() if worst(h, 'every', 8) * RT >= G)
    assert over == [874, 878, 884, 892], over
    # The closed histories and the event model, shipped.
    shipped = [worst(h, 'once') for h in closed.values()]
    assert (min(shipped), max(shipped)) == (795, 839) and event_worst('once') == 619
    # The open families, shipped.
    assert worst(opened['take-back every cycle'], 'once') == 927
    assert worst(opened['fire, revoke-only(refused) every cycle'], 'once') == 867
    assert worst(opened['fire, take-back, revoke-only(refused)...'], 'once') == 877
    # The bounded form: 819-863, slots 828-872, all under G.
    waits = [worst(h, 'once') for h in bounded.values()]
    assert (min(waits), max(waits)) == (819, 863) and (max(waits) + ENGAGED) * RT < G
    # Write round trips, in D_cycle's model: G's slot breaks first (20.55 ms), then D_cycle's own
    # writes (86.98 ms), and the cold raise outgrows the 64-round-trip turn only past 326.4 ms. At
    # one latency D_cycle breaks at 14.08 ms, so 81.4 ms against 86.98 ms compares two models.
    assert round(engaged_step_break_even() / 1000, 1) == 326.4
    assert break_even(slot_with_writes) < cycle_break_even() < engaged_step_break_even()
    assert 14.0 < cycle_uniform_break_even() / 1000 < 14.1

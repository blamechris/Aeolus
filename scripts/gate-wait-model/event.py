# ADR 0012's 2026-10-18 amendment: the review model of G's lower side (the gate waiter's wait with
# § 3's lane in it). Run from anywhere with `python3 scripts/gate-wait-model/event.py`. Constants are
# WatchdogLimits' and the scheduler's at the amendment; WatchdogLimitsTests pins the two modelled
# windows, and these scripts count the histories the windows do not cover.
#
# The event model of the scheduler's policy, imported by the event_*.py runners.
# Event model of SMCReadScheduler at c2eb163 (takeTurn fast path, enqueue, admitNext, nextTurn with
# the lane first and outside the quota), in round trips. The worst supervisor waiter W arrives last
# behind a 64-RT turn in flight, the grant path's K-key read and N - 3 five-RT readers; a snapshot
# slice is always waiting; § 3 runs a history of cycles, each a list of lane turns, sequential, and
# sleeps 1 s (87.31 RT) after each cycle. Phase: § 3's first turn arrives at time `phase` RT.
import collections
RT_S = 0.011453; INTERVAL = 1.0 / RT_S; QUOTA = 2; SNAP = 64
def wait_of_W(N, K, hist, phase, inflight=('snap', SNAP)):
    sup = collections.deque([('grant', K)] + [(('r', i), 5) for i in range(max(N - 3, 0))] + [('W', 5)])
    snap = collections.deque([('snap', SNAP)]); lane = collections.deque()
    over = 0
    cyc = 0; ti = 0; s3_next = phase; s3_waiting = False
    def nxt():
        nonlocal over
        if lane: return lane.popleft()
        if not snap:
            over = 0; return sup.popleft() if sup else None
        if sup and over < QUOTA:
            over += 1; return sup.popleft()
        over = 0; return snap.popleft()
    cur = inflight; t = 0.0; end = cur[1]
    while True:
        # § 3's cycle start, if it falls before this turn ends: its first turn parks in the lane
        if not s3_waiting and ti == 0 and cyc < len(hist) and s3_next <= end:
            lane.append(('s3', hist[cyc][0])); s3_waiting = True
        t = end; owner, L = cur
        if owner == 'W': return t - L
        if owner == 'snap': snap.append(('snap', SNAP))   # yieldTurn: enqueue, then admit
        n = nxt()
        if owner == 's3':
            s3_waiting = False
            ti += 1
            if ti == len(hist[cyc]):
                ti = 0; cyc += 1; s3_next = t + INTERVAL
            else:
                lane.append(('s3', hist[cyc][ti])); s3_waiting = True
        if n is None:
            n = nxt()
        if n is None:
            raise RuntimeError('idle')
        cur = n; end = t + n[1]

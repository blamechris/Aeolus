#!/bin/sh
# Restart run 1's record into a new capture directory, after a power cycle (ADR 0014, run-1
# amendment, item 13; the runbook's block R and ST-18). A power cycle ends every recorder, the
# watcher and the coordinator's session. This starts them again, with the runbook's own commands
# (PR-3 and PR-5) and its pinned paths, so that the check after the power cycle is read against a
# record. The owner runs it alone if the coordinator is lost.
#
#   restart-record.sh --watcher-sha <sha> [--captures <dir>]
#
#   --watcher-sha  the pinned watcher copy: <captures>/bin/run-watch-<sha>/scripts/run-watch/
#   --captures     default ~/aeolus-captures
#
# It makes <captures>/run1-<n>/ (n is the smallest free number, from 1), writes `CTX end` as the
# first line of its phases.log, and starts, in this order, into it: both samplers, the log stream,
# the record-only poll loop, the watcher and its companion. It writes the same .pid files as the
# runbook's commands, prints the directory and the PIDs, and does nothing else. It reads, and
# writes only into the new directory. It runs no fanctl, sudo or launchctl, and signals nothing
# (`kill -0` only asks whether a PID it started is still there).
#
# `CTX end` is first because a restart happens only after the forward writes have ended (items 10
# and 13): the new watcher starts in the teardown state. Outside a hold a helper restart is then
# a note, not an alert, and a sampler's own stop line ends its source for rule 12, so the
# record's own E-10 teardown is not heard as blind (#652's review, S2).
#
# Stop this record as the README of scripts/run-watch says (the runbook's E-10): by PID, the
# samplers with `kill -INT` first.
set -u

SAMPLER_NAME="smc-sampler-5b0d191"
SAMPLER_SHA256="f2e630924b6a55667eb8b0115a00cd19057588fc66d4d858f929ba71a903db8a"
PYTHON="/opt/homebrew/bin/python3"
LOGCMD="/usr/bin/log"
PERL="/usr/bin/perl"
SHASUM="/usr/bin/shasum"
PGREP="/usr/bin/pgrep"

CAPTURES="$HOME/aeolus-captures"
SHA=""

die() {
  echo "restart-record: $*" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --watcher-sha) [ $# -ge 2 ] || die "--watcher-sha needs a value"; SHA="$2"; shift 2 ;;
    --captures) [ $# -ge 2 ] || die "--captures needs a value"; CAPTURES="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (usage: restart-record.sh --watcher-sha <sha> [--captures <dir>])" ;;
  esac
done
[ -n "$SHA" ] || die "--watcher-sha is required (usage: restart-record.sh --watcher-sha <sha> [--captures <dir>])"
case "$SHA" in
  *[!0-9a-zA-Z._-]*) die "--watcher-sha may hold only letters, digits, '.', '_' and '-'" ;;
esac

SAMPLER="$CAPTURES/bin/$SAMPLER_NAME"
WATCH_DIR="$CAPTURES/bin/run-watch-$SHA/scripts/run-watch"

# Everything it needs is checked before anything is made or started.
[ -d "$CAPTURES" ] || die "$CAPTURES is not a directory"
[ -w "$CAPTURES" ] || die "$CAPTURES is not writable"
[ -x "$SAMPLER" ] || die "the pinned sampler is not executable: $SAMPLER"
[ -f "$WATCH_DIR/run_watch.py" ] || die "the pinned watcher is not at $WATCH_DIR/run_watch.py"
[ -f "$WATCH_DIR/watcher-down.sh" ] || die "the watcher's companion is not at $WATCH_DIR/watcher-down.sh"
[ -x "$PYTHON" ] || die "the pinned interpreter is not executable: $PYTHON"
[ -x "$LOGCMD" ] || die "$LOGCMD is not executable"
[ -x "$PERL" ] || die "$PERL is not executable (it stamps the CTX line)"
GOT=$("$SHASUM" -a 256 "$SAMPLER" | cut -d ' ' -f 1)
[ "$GOT" = "$SAMPLER_SHA256" ] || die "the staged sampler is not the pinned build (sha256 $GOT, pinned $SAMPLER_SHA256): do not record with it; take it to the architect"

# A record that is already running means this is not the restart after a power cycle.
RUNNING=$("$PGREP" -x "$SAMPLER_NAME" 2>/dev/null | tr '\n' ' ')
if [ -n "$RUNNING" ]; then
  echo "restart-record: WARNING: $SAMPLER_NAME is already running (pid $RUNNING). If this is not after a power cycle, you are starting a second record." >&2
fi

# The next free number: mkdir is atomic, so two runs cannot take the same one.
N=1
while ! mkdir "$CAPTURES/run1-$N" 2>/dev/null; do
  N=$((N + 1))
  [ "$N" -le 99 ] || die "no free run1-<n> directory below 100 in $CAPTURES"
done
DIR="$CAPTURES/run1-$N"

# CTX end first, stamped as the runbook stamps (perl's %.3f of the epoch); a plain note after it
# (the watcher ignores any line that is not a CTX line) says why.
STAMP=$("$PERL" -MTime::HiRes=time -e 'printf "%.3f", time') || STAMP=""
case "$STAMP" in
  [0-9]*.[0-9][0-9][0-9]) ;;
  *) rmdir "$DIR"; die "could not stamp the CTX line" ;;
esac
echo "$STAMP CTX end" > "$DIR/phases.log"
echo "$(date -u +%FT%TZ) restart-record.sh: CTX end is first because a restart happens only after the forward writes have ended (ADR 0014 items 10 and 13); this record is the teardown's" >> "$DIR/phases.log"

# The recorders (the runbook's PR-3).
nohup "$SAMPLER" --interval=0.1 --keys=F0Md,F1Md,Ftst,F0Tg,F1Tg,F0Ac,F1Ac > "$DIR/fans-10hz.ndjson" 2> "$DIR/fans-10hz.err" < /dev/null &
echo $! > "$DIR/fans-10hz.pid"
nohup "$SAMPLER" --interval=1 > "$DIR/package-1hz.ndjson" 2> "$DIR/package-1hz.err" < /dev/null &
echo $! > "$DIR/package-1hz.pid"
nohup "$LOGCMD" stream --style ndjson --level debug --predicate 'subsystem == "dev.aeolus.AeolusHelper" AND process == "AeolusHelper"' > "$DIR/helper-log.ndjson" 2>&1 < /dev/null &
echo $! > "$DIR/logstream.pid"
nohup sh -c 'while :; do date -u +%FT%TZ; sysctl -n vm.loadavg; notifyutil -g com.apple.system.thermalpressurelevel; sleep 5; done' > "$DIR/poll-5s.log" 2>&1 < /dev/null &
echo $! > "$DIR/poll.pid"

# The watcher and its companion, after the recorders (the runbook's PR-5).
nohup "$PYTHON" -I "$WATCH_DIR/run_watch.py" --dir "$DIR" >> "$DIR/watch.log" 2>&1 < /dev/null &
echo $! > "$DIR/watch.pid"
nohup /bin/sh "$WATCH_DIR/watcher-down.sh" "$DIR" > /dev/null 2>&1 < /dev/null &
echo $! > "$DIR/watcher-down.pid"

# Are they alive a moment later? Report each; a dead one is a failed restart, and says which.
sleep 1
STATUS=0
echo "restart-record: directory $DIR"
echo "restart-record: CTX end written first: this record starts in the teardown state (items 10 and 13)"
for NAME in fans-10hz package-1hz logstream poll watch watcher-down; do
  PID=$(cat "$DIR/$NAME.pid")
  if kill -0 "$PID" 2>/dev/null; then
    printf 'restart-record: %-13s pid %s\n' "$NAME" "$PID"
  else
    printf 'restart-record: %-13s pid %s IS NOT RUNNING (see %s)\n' "$NAME" "$PID" "$DIR" >&2
    STATUS=1
  fi
done
exit "$STATUS"

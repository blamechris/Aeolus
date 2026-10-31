#!/bin/sh
# The watcher's companion: speaks "watcher down" while watch.hb is stale, so a dead, stopped or
# hung watcher is heard. Start it beside the watcher; kill it by its PID at the end of the run.
#   usage: watcher-down.sh <capture dir> [max age in s, default 10] [period in s, default 3]
D=${1:?usage: watcher-down.sh <capture dir> [max age] [period]}; AGE=${2:-10}; EVERY=${3:-3}
while :; do
  hb=$(stat -f %m "$D/watch.hb" 2>/dev/null || echo 0)
  [ $(( $(date +%s) - hb )) -gt "$AGE" ] && "${SAY:-/usr/bin/say}" "watcher down"
  sleep "$EVERY"
done

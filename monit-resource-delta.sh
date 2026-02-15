#!/bin/sh
# Monit resource check that only "fails" (triggers alert) when the value is over
# threshold AND has changed by at least DELTA from the last time we alerted.
# This avoids repeated alerts every cycle for the same 100% condition; you only
# get an alert when the metric first crosses the threshold, or when it moves
# by another DELTA (e.g. 85% -> 95% sends a second alert).
# Usage: monit-resource-delta.sh <memory|swap|load|disk> <threshold> <delta>
#   For % metrics (memory, swap, disk): threshold and delta are percentages (e.g. 85, 10).
#   For load: threshold and delta are 1-min load average (e.g. 2, 0.5).
set -e

TYPE="${1:?}"
THRESHOLD="${2:?}"
DELTA="${3:?}"
STATE_DIR="/var/lib/monit/resource-state"
STATE_FILE="${STATE_DIR}/${TYPE}"

mkdir -p "$STATE_DIR"

get_value() {
  case "$TYPE" in
    memory)
      free -b | awk '/^Mem:/{printf "%.2f", $3/$2*100}'
      ;;
    swap)
      free -b | awk '/^Swap:/{printf "%.2f", ($2>0)?$3/$2*100:0}'
      ;;
    load)
      awk '{print $1}' /proc/loadavg
      ;;
    disk)
      df -P / | awk 'NR==2{gsub(/%/,""); print $5}'
      ;;
    *)
      echo "Unknown type: $TYPE" >&2
      exit 2
      ;;
  esac
}

current=$(get_value)

# Under threshold: clear state so next breach will alert, and report OK
under=$(awk -v c="$current" -v t="$THRESHOLD" 'BEGIN{print (c != "" && c+0 < t+0) ? 1 : 0}')
if [ "${under:-0}" = "1" ]; then
  rm -f "$STATE_FILE" 2>/dev/null || true
  exit 0
fi

# Over threshold: alert only if first time or change >= DELTA since last alert
alert=0
if [ ! -f "$STATE_FILE" ]; then
  alert=1
else
  last=$(cat "$STATE_FILE" 2>/dev/null || true)
  if [ -z "$last" ]; then
    alert=1
  else
    diff=$(awk -v a="$current" -v b="$last" 'BEGIN{d = a - b; print (d < 0) ? -d : d}')
    if [ -n "$diff" ] && [ "$(awk -v d="$diff" -v delta="$DELTA" 'BEGIN{print (d >= delta) ? 1 : 0}')" = "1" ]; then
      alert=1
    fi
  fi
fi

if [ "$alert" = "1" ]; then
  printf '%s' "$current" > "$STATE_FILE"
  exit 1
fi
exit 0

#!/usr/bin/env bash
# queue-status.sh — Live snapshot of queue depth and throughput.
#
# Run once for a snapshot, or with --watch N to poll every N seconds.
#
# Required env vars:
#   PROFILE, REGION, EVENT_ID, INCREMENT_BY, PUBLIC_API_URL
#
# Usage:
#   ./scripts/queue-status.sh               # single snapshot
#   ./scripts/queue-status.sh --watch 10    # refresh every 10s (Ctrl-C to stop)

set -euo pipefail

# ── Validate env vars ─────────────────────────────────────────────────────────
REQUIRED=(PROFILE REGION EVENT_ID INCREMENT_BY PUBLIC_API_URL)
MISSING=()
for V in "${REQUIRED[@]}"; do [ -z "${!V:-}" ] && MISSING+=("$V"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: missing required env vars: ${MISSING[*]}" >&2
  exit 1
fi

# ── Parse args ────────────────────────────────────────────────────────────────
WATCH_INTERVAL=0
if [ "${1:-}" = "--watch" ]; then
  WATCH_INTERVAL="${2:-5}"
fi

# ── Snapshot function ─────────────────────────────────────────────────────────
snapshot() {
  SERVING=$(curl -sf "${PUBLIC_API_URL}/serving_num?event_id=${EVENT_ID}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['serving_counter'])")
  WAITING=$(curl -sf "${PUBLIC_API_URL}/waiting_num?event_id=${EVENT_ID}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['waiting_num'])")

  echo "──────────────────────────────────────────────"
  echo " Queue Status — $EVENT_ID"
  echo " $(date)"
  echo "──────────────────────────────────────────────"
  echo "  Now serving : #${SERVING}"
  echo "  In queue    : ${WAITING} people"
  echo "  Inlet rate  : ${INCREMENT_BY} / min"

  if [ "$WAITING" -gt 0 ] && [ "$INCREMENT_BY" -gt 0 ]; then
    MINUTES=$(( WAITING / INCREMENT_BY ))
    SECONDS_LEFT=$(( WAITING * 60 / INCREMENT_BY ))
    if [ "$MINUTES" -ge 60 ]; then
      HOURS=$(( MINUTES / 60 ))
      MINS_REM=$(( MINUTES % 60 ))
      echo "  Est. clear  : ~${HOURS}h ${MINS_REM}m at current rate"
    else
      echo "  Est. clear  : ~${MINUTES} min at current rate"
    fi
  elif [ "$WAITING" -eq 0 ]; then
    echo "  Est. clear  : queue is empty"
  fi
  echo "──────────────────────────────────────────────"
}

# ── Run ───────────────────────────────────────────────────────────────────────
if [ "$WATCH_INTERVAL" -gt 0 ]; then
  echo "Watching every ${WATCH_INTERVAL}s — Ctrl-C to stop."
  echo ""
  while true; do
    snapshot
    echo ""
    sleep "$WATCH_INTERVAL"
  done
else
  snapshot
fi

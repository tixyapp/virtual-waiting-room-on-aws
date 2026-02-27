#!/usr/bin/env bash
# advance-serving.sh — Manually advance the serving counter by N positions.
#
# Use during testing to move users through the queue without waiting for the
# PeriodicInlet, or in production if you need to admit more users immediately.
#
# Requires awscurl for IAM-authenticated calls to the private API:
#   pip install awscurl
#
# Required env vars:
#   PROFILE, REGION, EVENT_ID, PRIVATE_API_URL, PUBLIC_API_URL
#
# Usage:
#   ./scripts/advance-serving.sh 10      # advance by 10
#   ./scripts/advance-serving.sh 500     # advance by 500
#   ADVANCE_BY=50 ./scripts/advance-serving.sh

set -euo pipefail

# ── Validate env vars ─────────────────────────────────────────────────────────
REQUIRED=(PROFILE REGION EVENT_ID PRIVATE_API_URL PUBLIC_API_URL)
MISSING=()
for V in "${REQUIRED[@]}"; do [ -z "${!V:-}" ] && MISSING+=("$V"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: missing required env vars: ${MISSING[*]}" >&2
  exit 1
fi

# ── Resolve advance amount ────────────────────────────────────────────────────
ADVANCE_BY="${1:-${ADVANCE_BY:-}}"
if [ -z "$ADVANCE_BY" ]; then
  echo "Usage: $0 <amount>"
  echo "  e.g.: $0 10     advance by 10"
  echo "  e.g.: $0 500    advance by 500"
  exit 1
fi

# Validate it's a positive integer
if ! [[ "$ADVANCE_BY" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: amount must be a positive integer, got: $ADVANCE_BY" >&2
  exit 1
fi

# ── Check awscurl is available ────────────────────────────────────────────────
if ! command -v awscurl &>/dev/null; then
  echo "ERROR: awscurl is required for IAM-authenticated API calls."
  echo "  Install: pip install awscurl"
  exit 1
fi

# ── Show current position before advancing ───────────────────────────────────
BEFORE=$(curl -sf "${PUBLIC_API_URL}/serving_num?event_id=${EVENT_ID}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['serving_counter'])")
echo "  Current serving counter : #${BEFORE}"
echo "  Advancing by            : +${ADVANCE_BY}"

# ── Advance ───────────────────────────────────────────────────────────────────
RESULT=$(awscurl \
  --service execute-api \
  --region "$REGION" \
  --profile "$PROFILE" \
  -X POST "${PRIVATE_API_URL}/increment_serving_counter" \
  -H "Content-Type: application/json" \
  -d "{\"event_id\": \"${EVENT_ID}\", \"increment_by\": ${ADVANCE_BY}}")

echo "  API response            : $RESULT"

# ── Show new position ─────────────────────────────────────────────────────────
AFTER=$(curl -sf "${PUBLIC_API_URL}/serving_num?event_id=${EVENT_ID}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['serving_counter'])")
WAITING=$(curl -sf "${PUBLIC_API_URL}/waiting_num?event_id=${EVENT_ID}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['waiting_num'])")

echo "  New serving counter     : #${AFTER}"
echo "  Remaining in queue      : ${WAITING}"

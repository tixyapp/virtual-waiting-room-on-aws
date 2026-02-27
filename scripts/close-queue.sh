#!/usr/bin/env bash
# close-queue.sh — Stop the PeriodicInlet when the sale ends or tickets sell out.
#
# Disables the EventBridge rule so the serving counter stops advancing.
# Users already in the queue can still claim their tokens (their requestId
# remains valid). No new users will be admitted past the current serving counter.
#
# Required env vars:
#   PROFILE, REGION, INLET_STACK_NAME, EVENT_ID, PUBLIC_API_URL
#
# Usage:
#   ./scripts/close-queue.sh

set -euo pipefail

# ── Validate env vars ─────────────────────────────────────────────────────────
REQUIRED=(PROFILE REGION INLET_STACK_NAME EVENT_ID PUBLIC_API_URL)
MISSING=()
for V in "${REQUIRED[@]}"; do [ -z "${!V:-}" ] && MISSING+=("$V"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: missing required env vars: ${MISSING[*]}" >&2
  exit 1
fi

echo "──────────────────────────────────────────────"
echo " CLOSING QUEUE — $EVENT_ID"
echo " $(date)"
echo "──────────────────────────────────────────────"

# ── Resolve and disable the rule ─────────────────────────────────────────────
echo -n "  Disabling PeriodicInlet rule... "
INLET_RULE=$(aws cloudformation describe-stack-resource \
  --stack-name "$INLET_STACK_NAME" \
  --logical-resource-id PeriodicInletRule \
  --profile "$PROFILE" --region "$REGION" \
  --query "StackResourceDetail.PhysicalResourceId" --output text)

aws events disable-rule \
  --name "$INLET_RULE" \
  --profile "$PROFILE" --region "$REGION" > /dev/null
echo "done"
echo "  Rule: $INLET_RULE"

# ── Final queue snapshot ──────────────────────────────────────────────────────
echo ""
echo "  Fetching final queue snapshot..."
SERVING=$(curl -sf "${PUBLIC_API_URL}/serving_num?event_id=${EVENT_ID}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['serving_counter'])")
WAITING=$(curl -sf "${PUBLIC_API_URL}/waiting_num?event_id=${EVENT_ID}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['waiting_num'])")

echo ""
echo "  Final serving counter : #${SERVING}"
echo "  Remaining in queue    : ${WAITING} (will not be served)"
echo ""
echo "──────────────────────────────────────────────"
echo " Sale closed. Inlet stopped."
if [ "$WAITING" -gt 0 ]; then
  echo " Note: $WAITING users are still in queue but the counter will not advance."
  echo "       They will see their wait time freeze and eventually time out."
fi
echo "──────────────────────────────────────────────"

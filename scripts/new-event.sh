#!/usr/bin/env bash
# new-event.sh — Prepare the stack for a new sale / new event ID.
#
# 1. Resets all Redis counters to zero (clean slate).
# 2. Updates the EventId parameter in the main CloudFormation stack
#    (propagates the new ID to all core-api Lambda env vars).
# 3. Updates the EventId parameter in the inlet stack.
# 4. Reminds you to update the CONFIG block in queue/index.html
#    and run upload-static-pages.sh.
#
# Requires awscurl for IAM-authenticated calls:
#   pip install awscurl
#
# Required env vars:
#   PROFILE, REGION, STACK_NAME, INLET_STACK_NAME,
#   EVENT_ID (the NEW event ID for the upcoming sale),
#   PRIVATE_API_URL
#
# Usage:
#   EVENT_ID=ye-poland-2026-05 ./scripts/new-event.sh
#   # or set EVENT_ID in your env block and run directly

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "  $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ WARNING: $*"; }
die()  { echo "  ✗ ERROR: $*" >&2; exit 1; }
hr()   { echo "──────────────────────────────────────────────────────"; }

# ── Validate env vars ─────────────────────────────────────────────────────────
REQUIRED=(PROFILE REGION STACK_NAME INLET_STACK_NAME EVENT_ID PRIVATE_API_URL)
MISSING=()
for V in "${REQUIRED[@]}"; do [ -z "${!V:-}" ] && MISSING+=("$V"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  die "missing required env vars: ${MISSING[*]}
       Set them from Section 0 of docs/deployment-strategy-prompt.md.
       Don't forget to set EVENT_ID to the NEW event ID."
fi

# ── Check awscurl is available ────────────────────────────────────────────────
if ! command -v awscurl &>/dev/null; then
  die "awscurl is required. Install: pip install awscurl"
fi

hr
echo " NEW EVENT SETUP — $EVENT_ID"
echo " Main stack   : $STACK_NAME"
echo " Inlet stack  : $INLET_STACK_NAME"
echo " $(date)"
hr

# ── Confirm ───────────────────────────────────────────────────────────────────
echo ""
echo " This will:"
echo "   1. Reset ALL Redis queue counters to zero"
echo "   2. Update EventId in main stack → $EVENT_ID"
echo "   3. Update EventId in inlet stack → $EVENT_ID"
echo ""
read -rp " Type the new EVENT_ID to confirm: " CONFIRM
if [ "$CONFIRM" != "$EVENT_ID" ]; then
  die "Confirmation did not match. Aborted."
fi
echo ""

# ── 1. Reset Redis counters ───────────────────────────────────────────────────
log "Resetting Redis counters for event '$EVENT_ID'..."
RESET_RESP=$(awscurl \
  --service execute-api \
  --region "$REGION" \
  --profile "$PROFILE" \
  -X POST "${PRIVATE_API_URL}/reset_initial_state" \
  -H "Content-Type: application/json" \
  -d "{\"event_id\": \"${EVENT_ID}\"}")
echo "  API response: $RESET_RESP"

if echo "$RESET_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('response')=='success' else 1)" 2>/dev/null; then
  ok "Redis counters reset"
else
  warn "Unexpected response from reset_initial_state. Verify manually before opening the sale."
fi

# ── 2. Update EventId in main stack ──────────────────────────────────────────
log "Updating EventId in main stack ($STACK_NAME)..."
log "(This re-deploys Lambda configs — takes ~2-3 min)"

aws cloudformation update-stack \
  --stack-name "$STACK_NAME" \
  --use-previous-template \
  --parameters \
    ParameterKey=EventId,ParameterValue="$EVENT_ID" \
    ParameterKey=ValidityPeriod,UsePreviousValue=true \
    ParameterKey=QueuePositionExpiryPeriod,UsePreviousValue=true \
    ParameterKey=EnableQueuePositionExpiry,UsePreviousValue=true \
    ParameterKey=IncrSvcOnQueuePositionExpiry,UsePreviousValue=true \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --profile "$PROFILE" --region "$REGION" \
  --output text > /dev/null

log "Waiting for main stack update..."
aws cloudformation wait stack-update-complete \
  --stack-name "$STACK_NAME" \
  --profile "$PROFILE" --region "$REGION"
ok "Main stack updated → EventId=$EVENT_ID"

# ── 3. Update EventId in inlet stack ─────────────────────────────────────────
log "Updating EventId in inlet stack ($INLET_STACK_NAME)..."
aws cloudformation update-stack \
  --stack-name "$INLET_STACK_NAME" \
  --use-previous-template \
  --parameters \
    ParameterKey=EventId,ParameterValue="$EVENT_ID" \
    ParameterKey=PrivateCoreApiEndpoint,UsePreviousValue=true \
    ParameterKey=CoreApiRegion,UsePreviousValue=true \
    ParameterKey=InletStrategy,UsePreviousValue=true \
    ParameterKey=IncrementBy,UsePreviousValue=true \
    ParameterKey=StartTime,UsePreviousValue=true \
    ParameterKey=EndTime,UsePreviousValue=true \
    ParameterKey=CloudWatchAlarmName,UsePreviousValue=true \
    ParameterKey=MaxSize,UsePreviousValue=true \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --profile "$PROFILE" --region "$REGION" \
  --output text > /dev/null

log "Waiting for inlet stack update..."
aws cloudformation wait stack-update-complete \
  --stack-name "$INLET_STACK_NAME" \
  --profile "$PROFILE" --region "$REGION"
ok "Inlet stack updated → EventId=$EVENT_ID"

# ── 4. Remind about static pages ─────────────────────────────────────────────
hr
echo " Done. New event '$EVENT_ID' is ready."
echo ""
echo " NEXT STEPS (manual):"
echo ""
echo " 1. Update CONFIG in source/sample-static-pages/queue/index.html:"
echo "      EVENT_ID:  '$EVENT_ID'"
echo "      PUBLIC_API_URL, BUY_TICKET_URL (if changed)"
echo ""
echo " 2. Upload the updated queue page:"
echo "      ./scripts/upload-static-pages.sh queue"
echo ""
echo " 3. Run pre-sale ~10 min before tickets open:"
echo "      INCREMENT_BY=<users_per_min> ./scripts/pre-sale.sh"
hr

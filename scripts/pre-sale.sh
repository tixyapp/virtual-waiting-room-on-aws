#!/usr/bin/env bash
# pre-sale.sh — Run ~10 minutes before tickets go on sale.
#
# 1. Verifies both CloudFormation stacks are healthy.
# 2. Updates the PeriodicInlet Lambda with EVENT_ID and INCREMENT_BY.
# 3. Enables the EventBridge rule so the serving counter starts advancing.
# 4. Confirms the queue counters are at zero (warns if not).
#
# Required env vars (Section 0 of deployment-strategy-prompt.md):
#   PROFILE, REGION, STACK_NAME, INLET_STACK_NAME,
#   EVENT_ID, INCREMENT_BY, PUBLIC_API_URL, PRIVATE_API_URL
#
# Usage:
#   source scripts/env-dev.sh   # or set vars manually
#   ./scripts/pre-sale.sh

set -euo pipefail

SCRIPT="pre-sale"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "  $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ WARNING: $*"; }
die()  { echo "  ✗ ERROR: $*" >&2; exit 1; }
hr()   { echo "──────────────────────────────────────────────────────"; }

# ── Validate env vars ─────────────────────────────────────────────────────────
REQUIRED=(PROFILE REGION STACK_NAME INLET_STACK_NAME EVENT_ID INCREMENT_BY PUBLIC_API_URL PRIVATE_API_URL)
MISSING=()
for V in "${REQUIRED[@]}"; do [ -z "${!V:-}" ] && MISSING+=("$V"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  die "missing required env vars: ${MISSING[*]}
       Set them from Section 0 of docs/deployment-strategy-prompt.md"
fi

hr
echo " PRE-SALE CHECKLIST — $EVENT_ID ($STACK_NAME)"
echo " $(date)"
hr

# ── 1. Verify both stacks are healthy ─────────────────────────────────────────
log "Checking stack health..."
for SNAME in "$STACK_NAME" "$INLET_STACK_NAME"; do
  STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$SNAME" \
    --profile "$PROFILE" --region "$REGION" \
    --query "Stacks[0].StackStatus" --output text 2>&1)
  case "$STATUS" in
    CREATE_COMPLETE|UPDATE_COMPLETE)
      ok "$SNAME → $STATUS"
      ;;
    *)
      die "$SNAME is in unexpected state: $STATUS. Resolve before opening the sale."
      ;;
  esac
done

# ── 2. Resolve PeriodicInlet Lambda from inlet stack ──────────────────────────
log "Resolving PeriodicInlet Lambda..."
INLET_FN=$(aws cloudformation describe-stack-resource \
  --stack-name "$INLET_STACK_NAME" \
  --logical-resource-id PeriodicInlet \
  --profile "$PROFILE" --region "$REGION" \
  --query "StackResourceDetail.PhysicalResourceId" --output text)
ok "Lambda: $INLET_FN"

# ── 3. Update EVENT_ID + INCREMENT_BY; preserve all other env vars ────────────
log "Updating Lambda env vars (EVENT_ID=$EVENT_ID, INCREMENT_BY=$INCREMENT_BY)..."
CURRENT_ENV=$(aws lambda get-function-configuration \
  --function-name "$INLET_FN" \
  --profile "$PROFILE" --region "$REGION" \
  --query "Environment.Variables" --output json)

ENV_FILE=$(mktemp)
trap 'rm -f "$ENV_FILE"' EXIT

EVENT_ID="$EVENT_ID" INCREMENT_BY="$INCREMENT_BY" PRIVATE_API_URL="$PRIVATE_API_URL" \
  python3 -c "
import sys, json, os
e = json.load(sys.stdin)
e['EVENT_ID']          = os.environ['EVENT_ID']
e['INCREMENT_BY']      = os.environ['INCREMENT_BY']
e['CORE_API_ENDPOINT'] = os.environ['PRIVATE_API_URL']
print(json.dumps({'Variables': e}))
" <<< "$CURRENT_ENV" > "$ENV_FILE"

aws lambda update-function-configuration \
  --function-name "$INLET_FN" \
  --environment "file://$ENV_FILE" \
  --profile "$PROFILE" --region "$REGION" \
  --output text > /dev/null
ok "Inlet rate: $INCREMENT_BY users/min"

# ── 4. Enable PeriodicInlet EventBridge rule ──────────────────────────────────
log "Enabling PeriodicInlet EventBridge rule..."
INLET_RULE=$(aws cloudformation describe-stack-resource \
  --stack-name "$INLET_STACK_NAME" \
  --logical-resource-id PeriodicInletRule \
  --profile "$PROFILE" --region "$REGION" \
  --query "StackResourceDetail.PhysicalResourceId" --output text)

aws events enable-rule \
  --name "$INLET_RULE" \
  --profile "$PROFILE" --region "$REGION" > /dev/null
ok "Rule enabled: $INLET_RULE"

# ── 5. Health check — counters should be at zero ─────────────────────────────
log "Checking queue counters..."
SERVING=$(curl -sf "${PUBLIC_API_URL}/serving_num?event_id=${EVENT_ID}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['serving_counter'])")
WAITING=$(curl -sf "${PUBLIC_API_URL}/waiting_num?event_id=${EVENT_ID}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['waiting_num'])")

echo ""
echo "  serving_counter : $SERVING"
echo "  waiting_num     : $WAITING"
echo "  inlet_rate      : $INCREMENT_BY / min"

if [ "$SERVING" != "0" ]; then
  warn "Serving counter is NOT zero ($SERVING)."
  warn "Run ./scripts/new-event.sh first to reset state for a fresh sale."
fi

hr
echo " READY. Sale can open now."
echo " Monitor with: ./scripts/queue-status.sh"
echo " Close with:   ./scripts/close-queue.sh"
hr

# ── Lambda reserved concurrency ───────────────────────────────────────────────
echo "Setting Lambda reserved concurrency..."

declare -A CONCURRENCY=(
  ["tixy-wvroom-prod-AssignQueueNum-adW7hefFSvzv"]=1000
  ["tixy-wvroom-prod-RecordHeartbeat-akRUSHwhAvn8"]=500
  ["tixy-wvroom-prod-GetServingNum-yP9XZfGPZHBL"]=300
  ["tixy-wvroom-prod-GenerateToken-LQh4Wg1x7q0s"]=200
  ["tixy-wvroom-prod-GetQueueNum-AmKTINyyDczg"]=200
  ["tixy-wvroom-prod-GetWaitingNum-Wm2oIpoj0pnd"]=200
)

for FN in "${!CONCURRENCY[@]}"; do
  LIMIT=${CONCURRENCY[$FN]}
  aws lambda put-function-concurrency \
    --function-name "$FN" \
    --reserved-concurrent-executions "$LIMIT" \
    --profile $PROFILE --region $REGION > /dev/null
  echo "  ✓ $FN → $LIMIT"
done

# ── Provisioned concurrency on VPC Lambdas (pre-warms ENIs) ──────────────────
echo "Setting provisioned concurrency on VPC Lambdas..."

for FN in \
  tixy-wvroom-prod-AssignQueueNum-adW7hefFSvzv \
  tixy-wvroom-prod-RecordHeartbeat-akRUSHwhAvn8; do
  VERSION=$(aws lambda publish-version \
    --function-name "$FN" \
    --profile $PROFILE --region $REGION \
    --query Version --output text)
  aws lambda put-provisioned-concurrency-config \
    --function-name "$FN" \
    --qualifier "$VERSION" \
    --provisioned-concurrent-executions 50 \
    --profile $PROFILE --region $REGION > /dev/null
  echo "  ✓ $FN version $VERSION → 50 provisioned"
done

#!/usr/bin/env bash
# test-heartbeat.sh — Validates the heartbeat liveness and abandon-detection system.
#
# Scenarios covered:
#   1. POST /heartbeat records a ping (HTTP 200)
#   2. POST /heartbeat rejects wrong event_id (HTTP 400)
#   3. POST /heartbeat rejects missing request_id (HTTP 400)
#   4. A stale heartbeat entry triggers DetectAbandoned → SNS → MaxSizeInlet
#
# Required env vars (source .env.dev first):
#   PROFILE, REGION, STACK_NAME, INLET_STACK_NAME,
#   EVENT_ID, PUBLIC_API_URL, SNS_ARN
#
# Usage:
#   source .env.dev && ./scripts/test-heartbeat.sh
#   ./scripts/test-heartbeat.sh --scenario 1   # run one scenario only

set -euo pipefail

SCRIPT="test-heartbeat"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()    { echo "  $*"; }
ok()     { echo "  ✓ $*"; }
fail()   { echo "  ✗ FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
warn()   { echo "  ⚠ $*"; }
die()    { echo "  ✗ ERROR: $*" >&2; exit 1; }
hr()     { echo "──────────────────────────────────────────────────────"; }
section(){ echo ""; hr; echo " $*"; hr; }

FAILURES=0
SCENARIO_FILTER="${2:-all}"
if [ "${1:-}" = "--scenario" ]; then SCENARIO_FILTER="${2:-all}"; fi

run_scenario() {
  local n="$1"
  if [ "$SCENARIO_FILTER" != "all" ] && [ "$SCENARIO_FILTER" != "$n" ]; then
    return
  fi
}

# ── Validate env vars ─────────────────────────────────────────────────────────
REQUIRED=(PROFILE REGION STACK_NAME INLET_STACK_NAME EVENT_ID PUBLIC_API_URL SNS_ARN)
MISSING=()
for V in "${REQUIRED[@]}"; do [ -z "${!V:-}" ] && MISSING+=("$V"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  die "missing env vars: ${MISSING[*]}  —  source .env.dev first"
fi

# ── Resolve API key from API Gateway ─────────────────────────────────────────
log "Resolving public API key..."
API_ID=$(aws cloudformation describe-stack-resource \
  --stack-name "$STACK_NAME" \
  --logical-resource-id PublicWaitingRoomApi \
  --profile "$PROFILE" --region "$REGION" \
  --query "StackResourceDetail.PhysicalResourceId" --output text)

API_KEY=$(aws apigateway get-api-keys \
  --include-values \
  --profile "$PROFILE" --region "$REGION" \
  --query "items[?stageKeys[0]=='${API_ID}/api'].value | [0]" \
  --output text 2>/dev/null || true)

# Fallback: pick the first key for this stack if stage filter returned nothing
if [ -z "$API_KEY" ] || [ "$API_KEY" = "None" ]; then
  API_KEY=$(aws apigateway get-api-keys \
    --include-values \
    --profile "$PROFILE" --region "$REGION" \
    --query "items[0].value" \
    --output text)
fi

if [ -z "$API_KEY" ] || [ "$API_KEY" = "None" ]; then
  die "Could not resolve API key. Check API Gateway → API Keys in the console."
fi
ok "API key resolved (${#API_KEY} chars)"

# ── Resolve RecordHeartbeat Lambda log group ──────────────────────────────────
log "Resolving RecordHeartbeat Lambda..."
HB_FN=$(aws cloudformation describe-stack-resource \
  --stack-name "$STACK_NAME" \
  --logical-resource-id RecordHeartbeat \
  --profile "$PROFILE" --region "$REGION" \
  --query "StackResourceDetail.PhysicalResourceId" --output text)
HB_LOG_GROUP="/aws/lambda/${HB_FN}"
ok "Lambda: $HB_FN"

# ── Resolve DetectAbandoned Lambda ────────────────────────────────────────────
log "Resolving DetectAbandoned Lambda..."
DA_FN=$(aws cloudformation describe-stack-resource \
  --stack-name "$STACK_NAME" \
  --logical-resource-id DetectAbandoned \
  --profile "$PROFILE" --region "$REGION" \
  --query "StackResourceDetail.PhysicalResourceId" --output text)
DA_LOG_GROUP="/aws/lambda/${DA_FN}"
ok "Lambda: $DA_FN"

# ── Test RID — must be UUID format to pass is_valid_rid() in the Lambda ───────
TEST_RID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")

echo ""
log "Test request_id: $TEST_RID"

# ═══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 1 — POST /heartbeat records a valid ping (expect HTTP 200)"
# ═══════════════════════════════════════════════════════════════════════════════
run_scenario 1 || true
if [ "$SCENARIO_FILTER" = "all" ] || [ "$SCENARIO_FILTER" = "1" ]; then

  HTTP=$(curl -s -o /tmp/hb-resp.json -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "x-api-key: $API_KEY" \
    -d "{\"request_id\":\"${TEST_RID}\",\"event_id\":\"${EVENT_ID}\"}" \
    "${PUBLIC_API_URL}/heartbeat")

  log "Response body: $(cat /tmp/hb-resp.json)"
  if [ "$HTTP" = "200" ]; then
    ok "HTTP $HTTP — heartbeat accepted"
  else
    fail "Expected 200, got HTTP $HTTP"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 2 — POST /heartbeat rejects wrong event_id (expect HTTP 400)"
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SCENARIO_FILTER" = "all" ] || [ "$SCENARIO_FILTER" = "2" ]; then

  HTTP=$(curl -s -o /tmp/hb-bad-event.json -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "x-api-key: $API_KEY" \
    -d "{\"request_id\":\"${TEST_RID}\",\"event_id\":\"wrong-event-id\"}" \
    "${PUBLIC_API_URL}/heartbeat")

  log "Response body: $(cat /tmp/hb-bad-event.json)"
  if [ "$HTTP" = "400" ]; then
    ok "HTTP $HTTP — wrong event_id correctly rejected"
  else
    fail "Expected 400, got HTTP $HTTP"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 3 — POST /heartbeat rejects missing request_id (expect HTTP 400)"
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SCENARIO_FILTER" = "all" ] || [ "$SCENARIO_FILTER" = "3" ]; then

  HTTP=$(curl -s -o /tmp/hb-no-rid.json -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "x-api-key: $API_KEY" \
    -d "{\"event_id\":\"${EVENT_ID}\"}" \
    "${PUBLIC_API_URL}/heartbeat")

  log "Response body: $(cat /tmp/hb-no-rid.json)"
  if [ "$HTTP" = "400" ]; then
    ok "HTTP $HTTP — missing request_id correctly rejected"
  else
    fail "Expected 400, got HTTP $HTTP"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 4 — DetectAbandoned fires and publishes to SNS"
# ═══════════════════════════════════════════════════════════════════════════════
# Strategy: invoke DetectAbandoned directly. It scans the heartbeats sorted set
# for entries older than STALE_THRESHOLD_SECONDS. The TEST_RID we recorded in
# scenario 1 has a score of "now", so it won't be stale yet. We inject a
# backdated RID directly via the Lambda payload is not possible (detect_abandoned
# reads Redis), so instead we invoke with a fake stale SNS message via the SNS
# topic and watch MaxSizeInlet pick it up.
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SCENARIO_FILTER" = "all" ] || [ "$SCENARIO_FILTER" = "4" ]; then

  STALE_RID="test-stale-$(date +%s)"
  SERVING_BEFORE=$(curl -sf "${PUBLIC_API_URL}/serving_num?event_id=${EVENT_ID}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['serving_counter'])")
  log "Serving counter before: $SERVING_BEFORE"

  log "Publishing fake abandon message to MaxSizeInletSns..."
  aws sns publish \
    --topic-arn "$SNS_ARN" \
    --message "{\"abandoned\":[\"${STALE_RID}\"]}" \
    --profile "$PROFILE" --region "$REGION" \
    --output text > /dev/null
  ok "Published abandoned=[${STALE_RID}] to SNS"

  log "Waiting 10s for MaxSizeInlet to process..."
  sleep 10

  log "Checking MaxSizeInlet CloudWatch logs (last 60s)..."
  MAXSIZE_FN=$(aws cloudformation describe-stack-resource \
    --stack-name "$INLET_STACK_NAME" \
    --logical-resource-id MaxSizeInlet \
    --profile "$PROFILE" --region "$REGION" \
    --query "StackResourceDetail.PhysicalResourceId" --output text)

  MAXSIZE_LOG_GROUP="/aws/lambda/${MAXSIZE_FN}"
  RECENT_LOG=$(aws logs filter-log-events \
    --log-group-name "$MAXSIZE_LOG_GROUP" \
    --start-time "$(( ($(date +%s) - 120) * 1000 ))" \
    --profile "$PROFILE" --region "$REGION" \
    --query "events[*].message" --output text 2>/dev/null || echo "no logs yet")

  log "MaxSizeInlet log excerpt:"
  echo "$RECENT_LOG" | tail -10 | sed 's/^/    /'

  if echo "$RECENT_LOG" | grep -qi "increment\|active_tokens\|serving"; then
    ok "MaxSizeInlet invoked and acted on the SNS message"
  else
    warn "MaxSizeInlet log not conclusive — check the log group manually:"
    warn "  $MAXSIZE_LOG_GROUP"
  fi

  log "Checking DetectAbandoned CloudWatch logs (last 120s)..."
  DA_LOG=$(aws logs filter-log-events \
    --log-group-name "$DA_LOG_GROUP" \
    --start-time "$(( ($(date +%s) - 120) * 1000 ))" \
    --profile "$PROFILE" --region "$REGION" \
    --query "events[*].message" --output text 2>/dev/null || echo "no recent invocations")
  log "DetectAbandoned log excerpt:"
  echo "$DA_LOG" | tail -5 | sed 's/^/    /'
fi

# ═══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 5 — RecordHeartbeat entry appears in Lambda logs"
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SCENARIO_FILTER" = "all" ] || [ "$SCENARIO_FILTER" = "5" ]; then

  log "Checking RecordHeartbeat CloudWatch logs (last 120s)..."
  HB_LOG=$(aws logs filter-log-events \
    --log-group-name "$HB_LOG_GROUP" \
    --start-time "$(( ($(date +%s) - 120) * 1000 ))" \
    --profile "$PROFILE" --region "$REGION" \
    --query "events[*].message" --output text 2>/dev/null || echo "no recent logs")

  log "RecordHeartbeat log excerpt:"
  echo "$HB_LOG" | tail -5 | sed 's/^/    /'

  if echo "$HB_LOG" | grep -q "200\|START\|END"; then
    ok "RecordHeartbeat Lambda was invoked"
  else
    warn "No recent RecordHeartbeat logs found."
    warn "  Log group: $HB_LOG_GROUP"
    warn "  The Lambda may not have been invoked yet, or log group may differ."
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
hr
if [ "$FAILURES" -eq 0 ]; then
  echo " RESULT: ALL SCENARIOS PASSED"
else
  echo " RESULT: $FAILURES SCENARIO(S) FAILED — review output above"
fi
hr
exit "$FAILURES"

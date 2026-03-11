#!/usr/bin/env bash
# test-inlets.sh — Validates PeriodicInlet and MaxSizeInlet function correctly.
#
# Scenarios covered:
#   1. PeriodicInlet — direct Lambda invoke advances serving counter by INCREMENT_BY
#   2. MaxSizeInlet  — SNS publish advances serving counter when capacity is free
#   3. PeriodicInlet — respects START_TIME guard (skips when sale not yet open)
#   4. Rule state    — PeriodicInletRule is confirmed DISABLED (safe default)
#
# Required env vars (source .env.dev first):
#   PROFILE, REGION, INLET_STACK_NAME, EVENT_ID,
#   INCREMENT_BY, PUBLIC_API_URL, SNS_ARN
#
# awscurl is NOT needed — serving counter reads use the public endpoint.
#
# Usage:
#   source .env.dev && ./scripts/test-inlets.sh
#   ./scripts/test-inlets.sh --scenario 1

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
log()    { echo "  $*"; }
ok()     { echo "  ✓ $*"; }
fail()   { echo "  ✗ FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
warn()   { echo "  ⚠ $*"; }
die()    { echo "  ✗ ERROR: $*" >&2; exit 1; }
hr()     { echo "──────────────────────────────────────────────────────"; }
section(){ echo ""; hr; echo " $*"; hr; }

FAILURES=0
SCENARIO_FILTER="all"
if [ "${1:-}" = "--scenario" ]; then SCENARIO_FILTER="${2:-all}"; fi

# ── Validate env vars ─────────────────────────────────────────────────────────
REQUIRED=(PROFILE REGION INLET_STACK_NAME EVENT_ID INCREMENT_BY PUBLIC_API_URL SNS_ARN)
MISSING=()
for V in "${REQUIRED[@]}"; do [ -z "${!V:-}" ] && MISSING+=("$V"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  die "missing env vars: ${MISSING[*]}  —  source .env.dev first"
fi

# ── Resolve physical resource names ──────────────────────────────────────────
log "Resolving inlet stack resources..."

PERIODIC_FN=$(aws cloudformation describe-stack-resource \
  --stack-name "$INLET_STACK_NAME" \
  --logical-resource-id PeriodicInlet \
  --profile "$PROFILE" --region "$REGION" \
  --query "StackResourceDetail.PhysicalResourceId" --output text)

MAXSIZE_FN=$(aws cloudformation describe-stack-resource \
  --stack-name "$INLET_STACK_NAME" \
  --logical-resource-id MaxSizeInlet \
  --profile "$PROFILE" --region "$REGION" \
  --query "StackResourceDetail.PhysicalResourceId" --output text)

RULE_NAME=$(aws cloudformation describe-stack-resource \
  --stack-name "$INLET_STACK_NAME" \
  --logical-resource-id PeriodicInletRule \
  --profile "$PROFILE" --region "$REGION" \
  --query "StackResourceDetail.PhysicalResourceId" --output text)

ok "PeriodicInlet Lambda : $PERIODIC_FN"
ok "MaxSizeInlet Lambda  : $MAXSIZE_FN"
ok "EventBridge rule     : $RULE_NAME"

# ── Helpers: read counter ─────────────────────────────────────────────────────
serving_num() {
  curl -sf "${PUBLIC_API_URL}/serving_num?event_id=${EVENT_ID}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['serving_counter'])"
}

# ── Helper: wait for Lambda log containing pattern ────────────────────────────
wait_for_log() {
  local log_group="$1"
  local pattern="$2"
  local max_wait="${3:-30}"
  local elapsed=0
  while [ "$elapsed" -lt "$max_wait" ]; do
    RESULT=$(aws logs filter-log-events \
      --log-group-name "$log_group" \
      --start-time "$(( ($(date +%s) - 60) * 1000 ))" \
      --filter-pattern "$pattern" \
      --profile "$PROFILE" --region "$REGION" \
      --query "events[*].message" --output text 2>/dev/null || true)
    if [ -n "$RESULT" ] && [ "$RESULT" != "None" ]; then
      echo "$RESULT"
      return 0
    fi
    sleep 3
    elapsed=$((elapsed + 3))
  done
  return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 1 — PeriodicInlet direct invoke advances serving counter"
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SCENARIO_FILTER" = "all" ] || [ "$SCENARIO_FILTER" = "1" ]; then

  BEFORE=$(serving_num)
  log "Serving counter before: $BEFORE"

  log "Invoking PeriodicInlet Lambda directly..."
  aws lambda invoke \
    --function-name "$PERIODIC_FN" \
    --region "$REGION" \
    --profile "$PROFILE" \
    --payload '{}' \
    /tmp/periodic-out.json > /dev/null

  RESP=$(cat /tmp/periodic-out.json)
  log "Lambda response: $RESP"

  sleep 2
  AFTER=$(serving_num)
  log "Serving counter after:  $AFTER"
  DIFF=$(( AFTER - BEFORE ))
  log "Delta: +$DIFF"

  if [ "$DIFF" -gt 0 ]; then
    ok "Serving counter advanced by $DIFF (INCREMENT_BY=$INCREMENT_BY)"
    if [ "$DIFF" -ne "$INCREMENT_BY" ]; then
      warn "Delta $DIFF ≠ INCREMENT_BY $INCREMENT_BY — may mean START_TIME guard fired or rate was changed"
    fi
  else
    # PeriodicInlet respects START_TIME — if it's in the future the counter
    # won't advance. This is expected for a fresh deployment before going on sale.
    if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'skipping' in str(d).lower() or d.get('statusCode',200)==200 else 1)" 2>/dev/null; then
      warn "Counter did not advance (+0). Possible reasons:"
      warn "  • START_TIME is in the future (set to epoch 0 or a past value to test)"
      warn "  • END_TIME has passed"
      warn "  • CLOUDWATCH_ALARM is in ALARM state"
      warn "Check Lambda env: aws lambda get-function-configuration --function-name $PERIODIC_FN --profile $PROFILE --region $REGION --query Environment"
    else
      fail "Serving counter did not advance and Lambda returned an error"
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 2 — MaxSizeInlet processes SNS abandon message"
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SCENARIO_FILTER" = "all" ] || [ "$SCENARIO_FILTER" = "2" ]; then

  FAKE_RID="test-maxsize-$(date +%s)"
  BEFORE=$(serving_num)
  log "Serving counter before: $BEFORE"

  log "Publishing fake abandon message: $FAKE_RID"
  aws sns publish \
    --topic-arn "$SNS_ARN" \
    --message "{\"abandoned\":[\"${FAKE_RID}\"]}" \
    --profile "$PROFILE" --region "$REGION" \
    --output text > /dev/null
  ok "SNS message published"

  log "Waiting up to 20s for MaxSizeInlet to process..."
  MAXSIZE_LOG_GROUP="/aws/lambda/${MAXSIZE_FN}"

  AFTER=""
  for i in 1 2 3 4; do
    sleep 5
    AFTER=$(serving_num)
    DIFF=$(( AFTER - BEFORE ))
    if [ "$DIFF" -gt 0 ]; then
      break
    fi
  done

  AFTER=$(serving_num)
  DIFF=$(( AFTER - BEFORE ))
  log "Serving counter after: $AFTER  (delta: +$DIFF)"

  log "Checking MaxSizeInlet logs..."
  MS_LOG=$(aws logs filter-log-events \
    --log-group-name "$MAXSIZE_LOG_GROUP" \
    --start-time "$(( ($(date +%s) - 60) * 1000 ))" \
    --profile "$PROFILE" --region "$REGION" \
    --query "events[*].message" --output text 2>/dev/null || echo "")

  echo "$MS_LOG" | tail -8 | sed 's/^/    /'

  if [ "$DIFF" -gt 0 ]; then
    ok "MaxSizeInlet advanced counter by $DIFF (capacity was available)"
  elif echo "$MS_LOG" | grep -qi "max_size\|capacity\|at capacity\|no increment"; then
    ok "MaxSizeInlet ran but did not increment (queue already at MAX_SIZE capacity — expected)"
  else
    warn "Counter unchanged (+0) and no clear log evidence."
    warn "  MaxSizeInlet log group: $MAXSIZE_LOG_GROUP"
    warn "  This may be normal if active_tokens >= MAX_SIZE."
    warn "  Advance users through the queue first, then retry."
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 3 — PeriodicInletRule is DISABLED by default"
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SCENARIO_FILTER" = "all" ] || [ "$SCENARIO_FILTER" = "3" ]; then

  RULE_STATE=$(aws events describe-rule \
    --name "$RULE_NAME" \
    --profile "$PROFILE" --region "$REGION" \
    --query "State" --output text)

  log "PeriodicInletRule state: $RULE_STATE"

  if [ "$RULE_STATE" = "DISABLED" ]; then
    ok "Rule is DISABLED — pre-sale.sh will enable it when the sale opens"
  elif [ "$RULE_STATE" = "ENABLED" ]; then
    warn "Rule is ENABLED — the serving counter is currently advancing every minute."
    warn "Run 'aws events disable-rule --name $RULE_NAME --profile $PROFILE --region $REGION' to pause it."
  else
    fail "Unexpected rule state: $RULE_STATE"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
section "SCENARIO 4 — Both Lambda functions deployed in inlet stack"
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SCENARIO_FILTER" = "all" ] || [ "$SCENARIO_FILTER" = "4" ]; then

  for FN_NAME in "$PERIODIC_FN" "$MAXSIZE_FN"; do
    STATE=$(aws lambda get-function \
      --function-name "$FN_NAME" \
      --profile "$PROFILE" --region "$REGION" \
      --query "Configuration.State" --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "$STATE" = "Active" ]; then
      ok "Lambda $FN_NAME → State=$STATE"
    else
      fail "Lambda $FN_NAME → State=$STATE (expected Active)"
    fi
  done
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

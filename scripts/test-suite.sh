#!/usr/bin/env bash
# test-suite.sh — Full system test suite for the TIXY Fair Queue.
#
# Runs all sub-scripts and collects a single pass/fail summary.
# Each sub-script can also be run independently.
#
# Sub-scripts:
#   scripts/test-heartbeat.sh  — heartbeat API + abandon detection
#   scripts/test-inlets.sh     — PeriodicInlet + MaxSizeInlet
#
# Required env vars (source .env.dev first):
#   PROFILE, REGION, STACK_NAME, INLET_STACK_NAME,
#   EVENT_ID, INCREMENT_BY, PUBLIC_API_URL, SNS_ARN
#
# Usage:
#   source .env.dev && ./scripts/test-suite.sh
#   source .env.dev && ./scripts/test-suite.sh --only heartbeat
#   source .env.dev && ./scripts/test-suite.sh --only inlets

set -uo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
hr()     { echo "══════════════════════════════════════════════════════"; }
log()    { echo "  $*"; }
die()    { echo "  ✗ ERROR: $*" >&2; exit 1; }

ONLY="${2:-all}"
if [ "${1:-}" = "--only" ]; then ONLY="${2:-all}"; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Validate env vars ─────────────────────────────────────────────────────────
REQUIRED=(PROFILE REGION STACK_NAME INLET_STACK_NAME EVENT_ID INCREMENT_BY PUBLIC_API_URL SNS_ARN)
MISSING=()
for V in "${REQUIRED[@]}"; do [ -z "${!V:-}" ] && MISSING+=("$V"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  die "missing env vars: ${MISSING[*]}  —  source .env.dev first"
fi

# ── Header ────────────────────────────────────────────────────────────────────
hr
echo " TIXY Fair Queue — Full Test Suite"
echo " Event   : $EVENT_ID"
echo " Stack   : $STACK_NAME"
echo " Inlet   : $INLET_STACK_NAME"
echo " Region  : $REGION"
echo " Started : $(date)"
hr
echo ""

TOTAL_FAILURES=0

run_suite() {
  local name="$1"
  local script="$2"

  echo ""
  hr
  echo " SUITE: $name"
  hr

  bash "$script"
  RC=$?
  if [ "$RC" -ne 0 ]; then
    echo ""
    echo "  Suite '$name' reported $RC failure(s)."
    TOTAL_FAILURES=$((TOTAL_FAILURES + RC))
  fi
}

# ── Stack health pre-check ────────────────────────────────────────────────────
echo " Pre-check: verifying stacks are healthy..."
echo ""

for SNAME in "$STACK_NAME" "$INLET_STACK_NAME"; do
  STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$SNAME" \
    --profile "$PROFILE" --region "$REGION" \
    --query "Stacks[0].StackStatus" --output text 2>&1)
  case "$STATUS" in
    CREATE_COMPLETE|UPDATE_COMPLETE)
      echo "  ✓ $SNAME → $STATUS"
      ;;
    *)
      die "$SNAME is in state '$STATUS'. Resolve before running tests."
      ;;
  esac
done

echo ""

# ── Verify both inlet Lambdas exist (dual-inlet sanity check) ─────────────────
echo " Pre-check: dual-inlet resources present..."
echo ""

for LID in PeriodicInlet MaxSizeInlet PeriodicInletRule MaxSizeInletSns; do
  PHYS=$(aws cloudformation describe-stack-resource \
    --stack-name "$INLET_STACK_NAME" \
    --logical-resource-id "$LID" \
    --profile "$PROFILE" --region "$REGION" \
    --query "StackResourceDetail.ResourceStatus" --output text 2>/dev/null || echo "MISSING")
  if [ "$PHYS" = "CREATE_COMPLETE" ] || [ "$PHYS" = "UPDATE_COMPLETE" ]; then
    echo "  ✓ $LID → $PHYS"
  else
    echo "  ✗ $LID → $PHYS"
    echo ""
    echo "  Dual-inlet mode is not fully deployed."
    echo "  Follow docs/dual-inlet.md Steps 1-4 to update the inlet stack."
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
  fi
done

echo ""

# ── Verify heartbeat resources in main stack ──────────────────────────────────
echo " Pre-check: heartbeat resources present..."
echo ""

for LID in RecordHeartbeat DetectAbandoned; do
  PHYS=$(aws cloudformation describe-stack-resource \
    --stack-name "$STACK_NAME" \
    --logical-resource-id "$LID" \
    --profile "$PROFILE" --region "$REGION" \
    --query "StackResourceDetail.ResourceStatus" --output text 2>/dev/null || echo "MISSING")
  if [ "$PHYS" = "CREATE_COMPLETE" ] || [ "$PHYS" = "UPDATE_COMPLETE" ]; then
    echo "  ✓ $LID → $PHYS"
  else
    echo "  ✗ $LID → $PHYS"
    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
  fi
done

echo ""

# Abort if pre-checks failed — sub-scripts will fail for the wrong reasons
if [ "$TOTAL_FAILURES" -gt 0 ]; then
  hr
  echo " PRE-CHECK FAILED — fix infrastructure issues before running tests"
  hr
  exit "$TOTAL_FAILURES"
fi

# ── Run sub-suites ────────────────────────────────────────────────────────────
if [ "$ONLY" = "all" ] || [ "$ONLY" = "heartbeat" ]; then
  run_suite "Heartbeat & Abandon Detection" "$SCRIPT_DIR/test-heartbeat.sh"
fi

if [ "$ONLY" = "all" ] || [ "$ONLY" = "inlets" ]; then
  run_suite "Periodic + MaxSize Inlets"  "$SCRIPT_DIR/test-inlets.sh"
fi

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
hr
echo " TEST SUITE COMPLETE — $(date)"
echo ""
if [ "$TOTAL_FAILURES" -eq 0 ]; then
  echo "  ✓ ALL TESTS PASSED"
else
  echo "  ✗ $TOTAL_FAILURES TEST(S) FAILED"
  echo ""
  echo "  Tip: re-run a single suite to focus on failures:"
  echo "    ./scripts/test-heartbeat.sh"
  echo "    ./scripts/test-inlets.sh"
  echo "    ./scripts/test-suite.sh --only heartbeat"
  echo "    ./scripts/test-suite.sh --only inlets"
fi
hr
echo ""
exit "$TOTAL_FAILURES"

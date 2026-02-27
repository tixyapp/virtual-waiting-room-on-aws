#!/usr/bin/env bash
# upload-static-pages.sh
#
# Uploads static HTML pages to S3 and invalidates the CloudFront
# distribution so changes are live immediately (no waiting for TTL).
#
# Usage:
#   ./scripts/upload-static-pages.sh                  # upload both pages
#   ./scripts/upload-static-pages.sh queue            # queue page only
#   ./scripts/upload-static-pages.sh buy-ticket       # buy-ticket page only
#
# Requires Section 0 env vars to be set:
#   PROFILE, REGION, STATIC_SITE_BUCKET, STATIC_SITE_CF_ID
#
# Example:
#   source docs/env-dev.sh        (or set manually from Section 0)
#   ./scripts/upload-static-pages.sh

# PROFILE=tixy-dev \
# REGION=eu-west-1 \
# STATIC_SITE_BUCKET=ye-poland-dev-site \
# STATIC_SITE_CF_ID=E2NWJFT6PM8O1F \
# ./scripts/upload-static-pages.sh queue

set -euo pipefail

# ── Repo root (script can be called from any directory) ───────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGES_DIR="$REPO_ROOT/source/sample-static-pages"

# ── Validate required env vars ────────────────────────────────────────────────
MISSING=()
for VAR in PROFILE REGION STATIC_SITE_BUCKET STATIC_SITE_CF_ID; do
  if [ -z "${!VAR:-}" ]; then
    MISSING+=("$VAR")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: missing required env vars: ${MISSING[*]}"
  echo ""
  echo "Set them from Section 0 of docs/deployment-strategy-prompt.md:"
  echo "  PROFILE=tixy-dev"
  echo "  REGION=eu-west-1"
  echo "  STATIC_SITE_BUCKET=ye-poland-dev-site"
  echo "  STATIC_SITE_CF_ID=E2NWJFT6PM8O1F"
  exit 1
fi

# ── Decide which pages to upload ──────────────────────────────────────────────
PAGE_FILTER="${1:-all}"

# List of "s3-key:source-path" pairs
ALL_PAGES=(
  "queue/index.html:queue/index.html"
  "buy-ticket/index.html:buy-ticket/index.html"
)

SELECTED_PAGES=()
case "$PAGE_FILTER" in
  all)
    SELECTED_PAGES=("${ALL_PAGES[@]}")
    ;;
  queue)
    SELECTED_PAGES=("queue/index.html:queue/index.html")
    ;;
  buy-ticket)
    SELECTED_PAGES=("buy-ticket/index.html:buy-ticket/index.html")
    ;;
  *)
    echo "ERROR: unknown page '$PAGE_FILTER'. Valid options: queue, buy-ticket, or omit for both."
    exit 1
    ;;
esac

# ── Upload ────────────────────────────────────────────────────────────────────
INVALIDATION_PATHS=()

echo ""
echo "Uploading to s3://${STATIC_SITE_BUCKET}/"
echo "CloudFront distribution: $STATIC_SITE_CF_ID"
echo "Profile: $PROFILE  Region: $REGION"
echo "──────────────────────────────────────────────"

for ENTRY in "${SELECTED_PAGES[@]}"; do
  S3_KEY="${ENTRY%%:*}"
  SRC_REL="${ENTRY##*:}"
  SRC="$PAGES_DIR/$SRC_REL"

  if [ ! -f "$SRC" ]; then
    echo "ERROR: source file not found: $SRC"
    exit 1
  fi

  echo -n "  uploading $S3_KEY ... "
  aws s3 cp "$SRC" \
    "s3://${STATIC_SITE_BUCKET}/${S3_KEY}" \
    --content-type "text/html" \
    --cache-control "no-cache" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --no-progress \
    --output text \
    2>&1
  echo "ok"

  INVALIDATION_PATHS+=("/${S3_KEY}")
done

echo ""

# ── CloudFront invalidation ───────────────────────────────────────────────────
# Without this, CloudFront serves the cached previous version for up to 24h.
echo -n "Creating CloudFront invalidation for: ${INVALIDATION_PATHS[*]} ... "

INVALIDATION_ID=$(aws cloudfront create-invalidation \
  --distribution-id "$STATIC_SITE_CF_ID" \
  --paths "${INVALIDATION_PATHS[@]}" \
  --profile "$PROFILE" \
  --query "Invalidation.Id" \
  --output text 2>&1)

echo "done (ID: $INVALIDATION_ID)"
echo ""
CF_DOMAIN=$(aws cloudfront get-distribution \
  --id "$STATIC_SITE_CF_ID" \
  --profile "$PROFILE" \
  --query "Distribution.DomainName" \
  --output text 2>/dev/null)

echo "Invalidation is propagating (~30–60s). Live URLs:"
for PATH_KEY in "${INVALIDATION_PATHS[@]}"; do
  echo "  https://${CF_DOMAIN}${PATH_KEY}"
done
echo ""
echo "Done. Changes will be visible once invalidation completes."

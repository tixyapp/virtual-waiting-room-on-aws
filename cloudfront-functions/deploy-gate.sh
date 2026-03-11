#!/usr/bin/env bash
# deploy-gate.sh — Inject current RSA public key into gate-lambda-edge.js
# and deploy it as a Lambda@Edge viewer-request function.
#
# Run this after every keypair rotation AND before each new sale season
# to ensure the embedded key matches the one used by generate_token.
#
# Prerequisites:
#   - aws CLI configured with credentials for us-east-1
#   - jq installed
#   - EVENT_ID env var set (used to fetch the correct public key)
#
# Usage:
#   PUBLIC_API=https://d3j12ztg52wyqw.cloudfront.net \
#   EVENT_ID=ye-poland-2026-04 \
#   FUNCTION_NAME=tixy-gate-phase2 \
#   DISTRIBUTION_ID=E2NWJFT6PM8O1F \
#   BEHAVIOR_PATH='DEFAULT' \
#     ./deploy-gate.sh

set -euo pipefail

PUBLIC_API="${PUBLIC_API:-https://d3j12ztg52wyqw.cloudfront.net}"
EVENT_ID="${EVENT_ID:?EVENT_ID is required}"
FUNCTION_NAME="${FUNCTION_NAME:-tixy-gate-phase2}"
DISTRIBUTION_ID="${DISTRIBUTION_ID:?DISTRIBUTION_ID is required}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "→ Fetching current public JWK from ${PUBLIC_API}/public_key?event_id=${EVENT_ID} ..."
JWK=$(curl -sf "${PUBLIC_API}/public_key?event_id=${EVENT_ID}")

# The /public_key endpoint returns a flat JWK object — not {keys: [...]}.
N=$(echo "${JWK}" | jq -r '.n')
E=$(echo "${JWK}" | jq -r '.e')

if [ -z "${N}" ] || [ "${N}" = "null" ]; then
  echo "ERROR: Could not extract RSA modulus (n) from public key response:" >&2
  echo "${JWK}" >&2
  exit 1
fi
if [ -z "${E}" ] || [ "${E}" = "null" ]; then
  echo "ERROR: Could not extract RSA exponent (e) from public key response:" >&2
  echo "${JWK}" >&2
  exit 1
fi

echo "→ Injecting public key (n length: ${#N}, e: ${E}) into gate-lambda-edge.js ..."
DEPLOY_FILE="${SCRIPT_DIR}/gate-lambda-edge.deploy.js"
sed \
  -e "s|__REPLACE_WITH_N__|${N}|" \
  -e "s|__REPLACE_WITH_E__|${E}|" \
  "${SCRIPT_DIR}/gate-lambda-edge.js" > "${DEPLOY_FILE}"

# Lambda@Edge must be deployed in us-east-1.
AWS_REGION="us-east-1"

echo "→ Zipping function code ..."
DEPLOY_ZIP="${SCRIPT_DIR}/gate-lambda-edge.deploy.zip"
(cd "${SCRIPT_DIR}" && zip -q "${DEPLOY_ZIP}" "$(basename "${DEPLOY_FILE}")")

echo "→ Checking if Lambda function ${FUNCTION_NAME} exists ..."
if aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}" &>/dev/null; then
  echo "→ Updating existing Lambda function ..."
  aws lambda update-function-code \
    --function-name "${FUNCTION_NAME}" \
    --zip-file "fileb://${DEPLOY_ZIP}" \
    --region "${AWS_REGION}" \
    --output text --query 'FunctionArn'

  echo "→ Waiting for update to complete ..."
  aws lambda wait function-updated \
    --function-name "${FUNCTION_NAME}" \
    --region "${AWS_REGION}"
else
  echo "ERROR: Lambda function ${FUNCTION_NAME} does not exist in us-east-1." >&2
  echo "Create it first via the AWS console or CloudFormation, then re-run this script." >&2
  exit 1
fi

echo "→ Publishing new Lambda version ..."
VERSION=$(aws lambda publish-version \
  --function-name "${FUNCTION_NAME}" \
  --description "gate Phase2 RS256 — key n=${N:0:20}..." \
  --region "${AWS_REGION}" \
  --query 'Version' --output text)
echo "   Published version: ${VERSION}"

FUNCTION_ARN=$(aws lambda get-function \
  --function-name "${FUNCTION_NAME}" \
  --region "${AWS_REGION}" \
  --query 'Configuration.FunctionArn' --output text)
VERSIONED_ARN="${FUNCTION_ARN%:*}:${VERSION}"
echo "   Versioned ARN: ${VERSIONED_ARN}"

echo "→ Updating CloudFront distribution ${DISTRIBUTION_ID} to use new Lambda@Edge version ..."
CONFIG=$(aws cloudfront get-distribution-config \
  --id "${DISTRIBUTION_ID}" \
  --query '{ETag: ETag, Config: DistributionConfig}')
ETAG=$(echo "${CONFIG}" | jq -r '.ETag')

# Update the DefaultCacheBehavior viewer-request Lambda@Edge association.
UPDATED_CONFIG=$(echo "${CONFIG}" | jq --arg arn "${VERSIONED_ARN}" \
  '.Config.DefaultCacheBehavior.LambdaFunctionAssociations = {
    "Quantity": 1,
    "Items": [{
      "LambdaFunctionARN": $arn,
      "EventType": "viewer-request",
      "IncludeBody": false
    }]
  }' | jq '.Config')

aws cloudfront update-distribution \
  --id "${DISTRIBUTION_ID}" \
  --if-match "${ETAG}" \
  --distribution-config "${UPDATED_CONFIG}" \
  --output text --query 'Distribution.Status'

echo ""
echo "✓ gate-lambda-edge deployed. Distribution update in progress (1-3 min to propagate)."
echo ""
echo "Verify with:"
echo "  curl -I https://$(aws cloudfront get-distribution \
    --id "${DISTRIBUTION_ID}" \
    --query 'Distribution.DomainName' --output text 2>/dev/null || echo '<domain>')/buy-ticket"
echo "  Expected: 302 Location: /queue/index.html"

# Cleanup temp files.
rm -f "${DEPLOY_FILE}" "${DEPLOY_ZIP}"

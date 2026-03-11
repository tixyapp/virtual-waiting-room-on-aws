#!/usr/bin/env bash
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
# Source .env.dev if env vars are not already set
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${PUBLIC_API_URL:-}" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../.env.dev"
fi

PROFILE="${PROFILE:-tixy-dev}"
REGION="${REGION:-eu-west-1}"
STACK_NAME="${STACK_NAME:-ye-poland-waiting-room-dev}"

# ── 1. Resolve CF distribution from the stack ────────────────────────────────
# List all CF distributions in the stack and pick the one whose domain matches
# PUBLIC_API_URL (the static-site CF lives in a separate manually-created stack).
echo "Resolving CloudFront distribution from stack..."

PUBLIC_API_DOMAIN="${PUBLIC_API_URL#https://}"   # strip https://
PUBLIC_API_DOMAIN="${PUBLIC_API_DOMAIN%%/*}"      # strip trailing path

CF_DIST_ID=$(aws cloudfront list-distributions \
  --profile "$PROFILE" \
  --query "DistributionList.Items[?DomainName=='${PUBLIC_API_DOMAIN}'].Id | [0]" \
  --output text)

if [[ -z "$CF_DIST_ID" || "$CF_DIST_ID" == "None" ]]; then
  echo "ERROR: Could not find a CloudFront distribution with domain ${PUBLIC_API_DOMAIN}"
  echo "       Check PUBLIC_API_URL in your .env.dev"
  exit 1
fi

echo "Distribution: $CF_DIST_ID  (domain: $PUBLIC_API_DOMAIN)"

# ── 2. Create cache policy (3-second TTL, keyed on event_id query string) ────
# Idempotent: reuse existing policy if already created.
echo "Resolving WaitingRoomPolling cache policy..."
POLICY_ID=$(aws cloudfront list-cache-policies \
  --type custom \
  --profile "$PROFILE" \
  --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='WaitingRoomPolling'].CachePolicy.Id | [0]" \
  --output text)

POLICY_CONFIG='{
  "Name": "WaitingRoomPolling",
  "Comment": "3-second TTL for serving_num and waiting_num - same value for all users",
  "DefaultTTL": 3,
  "MinTTL": 3,
  "MaxTTL": 3,
  "ParametersInCacheKeyAndForwardedToOrigin": {
    "EnableAcceptEncodingGzip": true,
    "EnableAcceptEncodingBrotli": true,
    "HeadersConfig": { "HeaderBehavior": "none" },
    "CookiesConfig": { "CookieBehavior": "none" },
    "QueryStringsConfig": {
      "QueryStringBehavior": "whitelist",
      "QueryStrings": { "Quantity": 1, "Items": ["event_id"] }
    }
  }
}'

if [[ -z "$POLICY_ID" || "$POLICY_ID" == "None" ]]; then
  echo "  → Not found, creating..."
  POLICY_ID=$(aws cloudfront create-cache-policy \
    --profile "$PROFILE" \
    --cache-policy-config "$POLICY_CONFIG" \
    --query "CachePolicy.Id" --output text)
  echo "  → Created: $POLICY_ID"
else
  echo "  → Found: $POLICY_ID — ensuring MinTTL=3..."
  POLICY_ETAG=$(aws cloudfront get-cache-policy --id "$POLICY_ID" \
    --profile "$PROFILE" --query "ETag" --output text)
  aws cloudfront update-cache-policy --id "$POLICY_ID" \
    --profile "$PROFILE" \
    --if-match "$POLICY_ETAG" \
    --cache-policy-config "$POLICY_CONFIG" \
    --query "CachePolicy.CachePolicyConfig.{MinTTL:MinTTL,DefaultTTL:DefaultTTL}" \
    --output json
fi

# ── 3. Fetch current distribution config ─────────────────────────────────────
echo "Fetching distribution config..."
ETAG=$(aws cloudfront get-distribution-config \
  --id "$CF_DIST_ID" --profile "$PROFILE" \
  --query "ETag" --output text)

aws cloudfront get-distribution-config \
  --id "$CF_DIST_ID" --profile "$PROFILE" \
  --query "DistributionConfig" > /tmp/cf-dist-config.json

# ── 4. Inject new cache behaviors via Python ──────────────────────────────────
echo "Injecting cache behaviors..."
python3 << PYEOF
import json

with open('/tmp/cf-dist-config.json') as f:
    config = json.load(f)

policy_id = '$POLICY_ID'

# Use the same origin as the DefaultCacheBehavior so requests reach API GW.
default_origin_id = config['DefaultCacheBehavior']['TargetOriginId']

# Build behaviors from scratch — do NOT deepcopy DefaultCacheBehavior.
# The DefaultCacheBehavior has an OriginRequestPolicyId that forwards x-api-key
# from the viewer, but the origin also has x-api-key as a custom origin header.
# CloudFront rejects any config where the same header appears in both places.
# Building from scratch avoids inheriting that conflicting ORP.
# x-api-key is injected by the custom origin header on every request, so no ORP
# is needed. event_id is forwarded automatically because it is in the cache key.
def make_behavior(path_pattern):
    return {
        'PathPattern':          path_pattern,
        'TargetOriginId':       default_origin_id,
        'ViewerProtocolPolicy': 'redirect-to-https',
        'Compress':             True,
        'SmoothStreaming':      False,
        'AllowedMethods': {
            'Quantity': 3,
            'Items': ['HEAD', 'GET', 'OPTIONS'],
            'CachedMethods': {'Quantity': 2, 'Items': ['HEAD', 'GET']},
        },
        'CachePolicyId':            policy_id,
        'FieldLevelEncryptionId':   '',
        'LambdaFunctionAssociations': {'Quantity': 0, 'Items': []},
        'FunctionAssociations':       {'Quantity': 0, 'Items': []},
        'TrustedKeyGroups':           {'Enabled': False, 'Quantity': 0, 'Items': []},
    }

existing_items = config.get('CacheBehaviors', {}).get('Items', [])
# Remove any stale versions of these paths (makes the script idempotent).
items = [b for b in existing_items if b['PathPattern'] not in ('/serving_num*', '/waiting_num*')]

# Strip OriginRequestPolicyId from every behavior (including DefaultCacheBehavior).
# The origin has x-api-key as a custom origin header; CloudFront rejects any
# UpdateDistribution where the same header appears in both a custom origin header
# and an ORP's forwarded-headers list. Removing the ORP is safe here because
# x-api-key is already injected via the custom origin header and the API GW
# responses use hardcoded Access-Control-Allow-Origin: '*'.
config['DefaultCacheBehavior'].pop('OriginRequestPolicyId', None)
for b in items:
    b.pop('OriginRequestPolicyId', None)

new_behaviors = [make_behavior('/serving_num*'), make_behavior('/waiting_num*')]
items = new_behaviors + items

config['CacheBehaviors'] = {'Quantity': len(items), 'Items': items}

with open('/tmp/cf-dist-config-updated.json', 'w') as f:
    json.dump(config, f)

print(f"Origin: {default_origin_id}")
print(f"Total behaviors after update: {len(items)}")
PYEOF

# ── 5. Apply the updated config ───────────────────────────────────────────────
echo "Applying updated distribution config..."
aws cloudfront update-distribution \
  --id "$CF_DIST_ID" \
  --if-match "$ETAG" \
  --distribution-config file:///tmp/cf-dist-config-updated.json \
  --profile "$PROFILE" \
  --query "Distribution.Status" --output text

echo ""
echo "Done. Distribution is deploying — takes ~2 min."
echo "Verify with:"
echo "  curl -sv '${PUBLIC_API_URL}/serving_num?event_id=${EVENT_ID}' 2>&1 | grep -i x-cache"
echo "  # Run twice — first call: Miss from cloudfront, second: Hit from cloudfront"
echo "  # NOTE: use curl -s (GET), not curl -sI (HEAD) — API GW does not support HEAD on this endpoint"
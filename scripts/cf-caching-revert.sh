#!/usr/bin/env bash
set -euo pipefail

# Reverts all changes made by cf-caching-fix.sh:
#   1. Removes /serving_num* and /waiting_num* cache behaviors
#   2. Deletes the WaitingRoomPolling cache policy

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${PUBLIC_API_URL:-}" ]]; then
  source "$SCRIPT_DIR/../.env.dev"
fi

PROFILE="${PROFILE:-tixy-dev}"

# ── 1. Resolve CF distribution by domain ──────────────────────────────────────
PUBLIC_API_DOMAIN="${PUBLIC_API_URL#https://}"
PUBLIC_API_DOMAIN="${PUBLIC_API_DOMAIN%%/*}"

echo "Resolving distribution for ${PUBLIC_API_DOMAIN}..."
CF_DIST_ID=$(aws cloudfront list-distributions \
  --profile "$PROFILE" \
  --query "DistributionList.Items[?DomainName=='${PUBLIC_API_DOMAIN}'].Id | [0]" \
  --output text)

echo "Distribution: $CF_DIST_ID"

# ── 2. Fetch current config + ETag ────────────────────────────────────────────
echo "Fetching distribution config..."
ETAG=$(aws cloudfront get-distribution-config \
  --id "$CF_DIST_ID" --profile "$PROFILE" \
  --query "ETag" --output text)

aws cloudfront get-distribution-config \
  --id "$CF_DIST_ID" --profile "$PROFILE" \
  --query "DistributionConfig" > /tmp/cf-revert-config.json

# ── 3. Strip the two behaviors added by cf-caching-fix.sh ────────────────────
echo "Removing /serving_num* and /waiting_num* behaviors..."
python3 << 'PYEOF'
import json

with open('/tmp/cf-revert-config.json') as f:
    config = json.load(f)

before = config.get('CacheBehaviors', {}).get('Items', [])
items  = [b for b in before if b['PathPattern'] not in ('/serving_num*', '/waiting_num*')]

removed = len(before) - len(items)
config['CacheBehaviors'] = {'Quantity': len(items), 'Items': items}

with open('/tmp/cf-revert-config-clean.json', 'w') as f:
    json.dump(config, f)

print(f"Removed {removed} behavior(s). Remaining: {len(items)}")
PYEOF

# ── 4. Apply reverted config ──────────────────────────────────────────────────
echo "Applying reverted distribution config..."
aws cloudfront update-distribution \
  --id "$CF_DIST_ID" \
  --if-match "$ETAG" \
  --distribution-config file:///tmp/cf-revert-config-clean.json \
  --profile "$PROFILE" \
  --query "Distribution.Status" --output text

# ── 5. Delete the WaitingRoomPolling cache policy ─────────────────────────────
echo "Looking up WaitingRoomPolling cache policy..."
POLICY_RESULT=$(aws cloudfront list-cache-policies \
  --type custom \
  --profile "$PROFILE" \
  --query "CachePolicyList.Items[?CachePolicy.CachePolicyConfig.Name=='WaitingRoomPolling'].[CachePolicy.Id,CachePolicy.LastModifiedTime]" \
  --output text)

POLICY_ID=$(echo "$POLICY_RESULT" | awk '{print $1}')

if [[ -z "$POLICY_ID" || "$POLICY_ID" == "None" ]]; then
  echo "  → WaitingRoomPolling policy not found, nothing to delete."
else
  POLICY_ETAG=$(aws cloudfront get-cache-policy \
    --id "$POLICY_ID" --profile "$PROFILE" \
    --query "ETag" --output text)

  aws cloudfront delete-cache-policy \
    --id "$POLICY_ID" \
    --if-match "$POLICY_ETAG" \
    --profile "$PROFILE"

  echo "  → Deleted policy $POLICY_ID"
fi

echo ""
echo "Done. Distribution is deploying back to original state (~2 min)."
echo "Verify with:"
echo "  curl -sI '${PUBLIC_API_URL}/serving_num?event_id=${EVENT_ID}' | grep -E 'HTTP/|x-cache'"

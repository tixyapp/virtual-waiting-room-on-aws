# CloudFront Caching Fix — `serving_num` & `waiting_num`

**Date:** 2026-03-11  
**Env:** prod (`tixy-wvroom-prod` / `d29hlz7tunu3v5.cloudfront.net`)  
**Script:** `scripts/cf-caching-fix.sh`

---

## Goal

Add 3-second CloudFront cache behaviors for `/serving_num*` and `/waiting_num*` so that
all users polling from the same CF edge location share a single cached response. Without
this, every poll from every user triggers a Lambda invocation — catastrophic at high
concurrency.

---

## Architecture

```
Browser (queue page)
  → CloudFront  d29hlz7tunu3v5.cloudfront.net
    → API Gateway  yhg16r8f9l.execute-api.eu-west-1.amazonaws.com  (OriginPath: /api)
      → Lambda  GetServingNum / GetWaitingNum
```

Key facts about the distribution:
- **`x-api-key` is a custom origin header** on the `waiting-room-public-api` origin.
  CF injects it automatically on every request to API GW. The queue page JS does **not**
  send `x-api-key` — it relies entirely on CF to inject it.
- All API GW endpoints return `Cache-Control: no-cache`, so caching must be forced via
  `MinTTL > 0` in the cache policy.
- All API GW CORS responses use hardcoded `Access-Control-Allow-Origin: '*'`, so
  forwarding the `Origin` viewer header is not required.
- **Do not use `curl -sI` (HEAD)** to test these endpoints — API GW only defines GET and
  OPTIONS for `/serving_num` and `/waiting_num`. HEAD returns 403
  `MissingAuthenticationTokenException`. Use `curl -s` (GET).

---

## Bugs fixed in `cf-caching-fix.sh`

### Bug 1 — Python block never wrote the output file

The original script read the distribution config, modified it in memory, but never called
`json.dump()`. Step 5 (`aws cloudfront update-distribution`) referenced
`/tmp/cf-dist-config-updated.json` which either didn't exist or was stale from a prior
run. **Fix:** added `json.dump(config, f)` before the heredoc closes.

### Bug 2 — `MinTTL: 0` meant caching never happened

The `WaitingRoomPolling` cache policy was created with `MinTTL: 0`. When `MinTTL` is 0,
CloudFront respects the origin's `Cache-Control` headers. API GW returns
`Cache-Control: no-cache`, so CF never cached anything — every request was a Miss.
**Fix:** set `MinTTL: 3` (same as `DefaultTTL` and `MaxTTL`). This forces CF to cache
for at least 3 seconds regardless of origin response headers.

### Bug 3 — `OriginRequestPolicyId` conflict with custom origin header

The original script used `copy.deepcopy(DefaultCacheBehavior)` as the template for new
behaviors. The `DefaultCacheBehavior` (and other existing behaviors) had
`OriginRequestPolicyId = AllViewerExceptHostHeader`
(`b689b0a8-53d0-40ab-baf2-68738e2966ac`), which is configured to forward all viewer
headers — including `x-api-key` — to origin.

AWS `UpdateDistribution` rejects any config where the **same header appears in both an
Origin Request Policy and the origin's custom headers**. The distribution has `x-api-key`
as a custom origin header, so the ORP created a conflict, causing:

```
InvalidArgument: The parameter Header Name with value x-api-key is not allowed
as both an origin custom header and a forward header.
```

**Fix:**
1. Build new behaviors **from scratch** (not deepcopy) with only the minimal required
   fields — no `OriginRequestPolicyId`.
2. Strip `OriginRequestPolicyId` from `DefaultCacheBehavior` and all existing
   `CacheBehaviors` before writing the updated config. This is safe because `x-api-key`
   is already handled by the custom origin header and CORS headers are hardcoded.

---

## Cache policy: `WaitingRoomPolling`

| Field | Value |
|---|---|
| MinTTL | 3 s |
| DefaultTTL | 3 s |
| MaxTTL | 3 s |
| Cache key — headers | none |
| Cache key — cookies | none |
| Cache key — query strings | `event_id` only |

All users watching the same event share the same cached counter for 3 seconds.
`x-api-key` is **not** in the cache key (it's a secret injected by CF; it must not vary
the cache).

---

## Behaviors added to the distribution

| Path pattern | Cache policy | Origin Request Policy | Notes |
|---|---|---|---|
| `/serving_num*` | WaitingRoomPolling | none | x-api-key via custom origin header |
| `/waiting_num*` | WaitingRoomPolling | none | x-api-key via custom origin header |

Behaviors are prepended to the list so they take priority over any `*` default.

---

## How to run

```bash
source .env.prod && bash scripts/cf-caching-fix.sh
```

The script is **idempotent** — safe to re-run. It:
1. Finds the CF distribution by `PUBLIC_API_URL` domain.
2. Creates or updates the `WaitingRoomPolling` cache policy (enforces `MinTTL: 3`).
3. Fetches the current distribution config.
4. Strips `OriginRequestPolicyId` from all behaviors (avoids the custom-header conflict).
5. Injects `/serving_num*` and `/waiting_num*` behaviors (replacing stale versions).
6. Applies the updated config (~2 min to deploy).

To revert (remove the two behaviors and delete the cache policy):

```bash
source .env.prod && bash scripts/cf-caching-revert.sh
```

---

## Verification

```bash
# Run twice — expect Miss then Hit
curl -sv 'https://d29hlz7tunu3v5.cloudfront.net/serving_num?event_id=ye-poland-2026-04' \
  2>&1 | grep -i x-cache
curl -sv 'https://d29hlz7tunu3v5.cloudfront.net/serving_num?event_id=ye-poland-2026-04' \
  2>&1 | grep -i x-cache
```

Expected output:
```
< X-Cache: Miss from cloudfront   ← first request, CF fetches from API GW and caches
< X-Cache: Hit from cloudfront    ← served from cache, no Lambda invoked
```

> **Note:** Hitting different CF edge PoPs (e.g. WAW51-P3 vs WAW51-P6) may produce
> alternating Miss/Hit — each PoP maintains its own cache. This is expected and normal.

# Heartbeat, Abandon Detection & Phase 2 Gate — Change Summary

Deployed: 2026-03-05
Stack: `ye-poland-waiting-room-dev` / `ye-poland-inlet-dev`

---

## What Changed

### 1. Heartbeat liveness system

Users who silently leave the queue (close tab, navigate away) are now detected
and their positions reclaimed so users behind them move through faster.

**New shared library**
- `source/shared/virtual-waiting-room-on-aws-common/vwr/common/heartbeat.py`
  — Redis sorted set helpers: `record_heartbeat`, `get_abandoned`,
  `remove_heartbeat`, `clear_all_heartbeats`
  — Key: bare string `heartbeats` (no EVENT_ID prefix — one cluster per event)

**New Lambda: `RecordHeartbeat`**
- File: `source/core-api/lambda_functions/record_heartbeat.py`
- VPC Lambda (same subnet/SG as existing functions)
- Upserts `{request_id: unix_timestamp}` into the `heartbeats` sorted set
- Triggered by: `POST /heartbeat` on the Public API (API key auth, CORS enabled)

**New Lambda: `DetectAbandoned`**
- File: `source/core-api/lambda_functions/detect_abandoned.py`
- VPC Lambda, triggered by EventBridge `rate(1 minute)`
- Queries sorted set for entries with score older than `STALE_THRESHOLD_SECONDS` (default: 90s)
- Removes stale entries from the sorted set
- Publishes `{"abandoned": [...]}` to `MaxSizeInletSns`
- `MaxSizeInlet` then calls `POST /update_session` (status=-1) + `POST /increment_serving_counter`

**Queue page JS** (`source/sample-static-pages/queue/index.html`)
- Sends `POST /heartbeat` every 30 seconds while waiting in queue
- Stops heartbeat immediately before `POST /generate_token` (token issuance)
- Sends a final best-effort ping via `navigator.sendBeacon` on `visibilitychange`
  (catches tab-switch / close without stopping the interval)

**`reset_initial_state`** (`source/core-api/lambda_functions/reset_initial_state.py`)
- Now calls `clear_all_heartbeats(rc)` alongside the existing counter resets
- The `heartbeats` sorted set is wiped clean before each new event

---

### 2. Inlet strategy switched to MaxSize

Inlet stack (`ye-poland-inlet-dev`) updated from `InletStrategy=Periodic`
to `InletStrategy=MaxSize` with `MaxSize=1000`.

- `MaxSizeInletSns` SNS topic is now live:
  `arn:aws:sns:eu-west-1:081111355078:ye-poland-inlet-dev-MaxSizeInletSns-YGNNzOP8gxjH`
- `MaxSizeInlet` Lambda is now active — advances the serving counter based on
  actual active token capacity rather than a fixed time interval
- `PeriodicInlet` and `PeriodicInletRule` are now inactive (condition-gated)

> **Note:** `pre-sale.sh` still references `PeriodicInlet` — update it before
> the next sale to use the MaxSize inlet if you want it managed by that script.

---

### 3. gate.js — Phase 1.5 (expiry + structure check)

File: `cloudfront-functions/gate.js`
Function: `ye-poland-dev-gate`

**Previous behaviour:** presence check only — any non-empty `wvroom_token`
cookie was accepted, including expired or malformed tokens.

**New behaviour:**
- Checks JWT has exactly 3 dot-separated segments (malformed tokens rejected)
- Decodes payload and checks `exp` claim — expired tokens are redirected
- Still accepts `wvroom_token` as URL query param (dev cross-domain flow)
- Redirects to `/queue/index.html` on any failure

**Note on Phase 2 (RS256 signature verification):**
CloudFront Functions (`cloudfront-js-2.0`) only exposes `crypto.createHash`
and `crypto.createHmac` — no RSA primitives. Full RS256 signature verification
requires Lambda@Edge. The Phase 2 implementation is ready at
`cloudfront-functions/gate-lambda-edge.js` and can be deployed using
`cloudfront-functions/deploy-gate.sh` when Lambda@Edge is set up.

---

### 4. New CloudFormation resources (main stack)

| Resource | Type | Purpose |
|---|---|---|
| `RecordHeartbeat` | `AWS::Lambda::Function` | Handles `POST /heartbeat` |
| `RecordHeartbeatPermission` | `AWS::Lambda::Permission` | API Gateway → Lambda invoke |
| `DetectAbandonedRole` | `AWS::IAM::Role` | Secrets Manager + `sns:Publish` |
| `DetectAbandoned` | `AWS::Lambda::Function` | EventBridge-triggered abandon scanner |
| `DetectAbandonedEventRule` | `AWS::Events::Rule` | `rate(1 minute)` schedule |
| `DetectAbandonedEventRulePermissions` | `AWS::Lambda::Permission` | EventBridge → Lambda invoke |

**New parameters:**

| Parameter | Value used | Purpose |
|---|---|---|
| `SessionEventsSnsArn` | SNS ARN above | Target for `DetectAbandoned` publish |
| `StaleThresholdSeconds` | `90` | Seconds before a user is considered abandoned |

---

## Key Constants

| Constant | Value |
|---|---|
| Heartbeat interval | 30s (queue page JS) |
| Stale threshold | 90s = 3 missed pings |
| Redis key | `heartbeats` (bare string) |
| `DetectAbandoned` schedule | every 1 min |
| `MaxSize` (inlet capacity) | 1000 |

---

## Files Changed

| File | Change |
|---|---|
| `source/shared/.../vwr/common/heartbeat.py` | New — sorted set helpers |
| `source/core-api/lambda_functions/record_heartbeat.py` | New — heartbeat Lambda |
| `source/core-api/lambda_functions/detect_abandoned.py` | New — abandon detection Lambda |
| `source/core-api/lambda_functions/reset_initial_state.py` | Added `clear_all_heartbeats` |
| `source/sample-static-pages/queue/index.html` | Added heartbeat JS |
| `cloudfront-functions/gate.js` | Phase 1.5 — expiry + structure check |
| `cloudfront-functions/gate-lambda-edge.js` | New — Phase 2 Lambda@Edge (not yet deployed) |
| `cloudfront-functions/deploy-gate.sh` | New — deploy script for Lambda@Edge gate |
| `deployment/virtual-waiting-room-on-aws.json` | 6 new resources, 2 new parameters |
| `deployment/virtual-waiting-room-on-aws-swagger-public-api.json` | Added `POST /heartbeat` |

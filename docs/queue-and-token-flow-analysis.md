# Queue Logic & Token Flow — Technical Analysis

## Overview

The Virtual Waiting Room uses two data stores working together:

- **Redis (ElastiCache)** — fast atomic counters for real-time state
- **DynamoDB** — durable persistence for queue positions, tokens, and session state

---

## Queue Logic

### Core Redis Counters

| Counter | Meaning |
|---|---|
| `queue_counter` | Total requests ever enqueued |
| `serving_counter` | Positions now allowed through |
| `token_counter` | Tokens successfully issued |
| `expired_queue_counter` | Positions that expired without a token |
| `max_queue_position_expired` | Highest position confirmed expired |

---

### Queue Assignment (`assign_queue_num.py`)

Triggered by SQS batch messages:

1. Atomically increments `queue_counter` by batch size (e.g. 10 messages → one `INCRBY 10`)
2. Back-calculates starting position: `start = cur_count - (batch_size - 1)`
3. Writes each request to DynamoDB with its assigned position and `entry_time`
4. Deletes processed SQS messages

The atomic increment ensures no two requests ever receive the same position, even under concurrent load.

**DynamoDB schema — `QUEUE_POSITION_ENTRYTIME_TABLE`:**

| Field | Type | Description |
|---|---|---|
| `request_id` | String (PK) | API Gateway request ID |
| `queue_position` | Number | Assigned queue position |
| `entry_time` | Number | Unix timestamp of entry |
| `event_id` | String | Waiting room event ID |
| `status` | Number | Record status |

---

### Serving Counter Advancement

The serving counter is advanced by **inlet strategies** — pluggable Lambda functions that decide how fast users are let through. This is fully decoupled from the core API.

#### Max Size Inlet (`max_size_inlet.py`)

Capacity-based — lets in only as many users as there is room for:

```
capacity    = MAX_SIZE - active_tokens
increment_by = min(users_exited, capacity)
```

Triggers via SNS when sessions complete or are abandoned.

#### Periodic Inlet (`periodic_inlet.py`)

Time-based — advances by a fixed number on a schedule:

- Runs on a CloudWatch scheduled rule (e.g. every minute)
- Checks a CloudWatch alarm — pauses automatically if the backend is in `ALARM` state
- Only fires within a configured `START_TIME` / `END_TIME` window

---

### Queue Position Expiry

Prevents stale "ghost" positions from blocking the queue indefinitely.

**Expiry calculation:**

```
expiry_start = max(entry_time, serving_counter_issue_time)
expires_at   = expiry_start + QUEUE_POSITION_EXPIRY_PERIOD
```

The `max()` is a fairness guard — it prevents penalising users who queued before the serving counter snapshot was taken.

**Expiry processing (`set_max_queue_position_expired.py`):**

1. Scans serving counter DynamoDB snapshots beyond current `max_queue_position_expired`
2. For each snapshot, checks if the expiry period has elapsed
3. Increments `expired_queue_counter` and `serving_counter` to skip expired positions
4. Updates `max_queue_position_expired`

**DynamoDB schema — `SERVING_COUNTER_ISSUEDAT_TABLE`:**

| Field | Type | Description |
|---|---|---|
| `event_id` | String (PK) | Waiting room event ID |
| `serving_counter` | Number (SK) | Counter value at snapshot time |
| `issue_time` | Number | Unix timestamp of snapshot |
| `queue_positions_served` | Number | Positions served at this counter value |

---

### Waiting Room Math

```
waiting  = queue_counter - token_counter - expired_queue_counter
position = queue_position - serving_counter   (user's relative distance from front)
```

---

## Token Flow

### Generation (`generate_token.py`)

Complete check sequence before issuing a token:

```
1. Validate request_id (UUID format) + event_id
2. Fetch queue_position from DynamoDB
3. queue_position <= serving_counter?    No → 202 "not served yet"
4. Expiry enabled + not yet in token table? → expired? → 410 Gone
5. Token already exists + session_status != 0? → 400 "token expired/used"
6. Write token record to DynamoDB (session_status = 0)
7. Sign JWT (RS256, private key from Secrets Manager)
8. Increment token_counter in Redis
9. Return access_token + refresh_token + id_token
```

Three token types are issued together in an OAuth2-style response:

| Token | Purpose |
|---|---|
| Access token | Authorises API calls |
| Refresh token | Renews the access token |
| ID token | Carries identity claims |

**JWT claims structure:**

```json
{
  "aud": "<event_id>",
  "sub": "<request_id>",
  "queue_position": 1234,
  "token_use": "access",
  "iat": 1700000000,
  "nbf": 1700000000,
  "exp": 1700003600,
  "iss": "https://..."
}
```

**DynamoDB schema — `TOKEN_TABLE`:**

| Field | Type | Description |
|---|---|---|
| `request_id` | String (PK) | Subject of the token |
| `event_id` | String | Audience of the token |
| `issued_at` | Number | Unix timestamp |
| `not_before` | Number | Unix timestamp |
| `expires` | Number | Unix timestamp |
| `queue_number` | Number | Queue position |
| `issuer` | String | Token issuer URL |
| `session_status` | Number | `0` active, `1` completed, `-1` abandoned |

Index `EventExpiresIndex` (`event_id` + `expires`) supports efficient active-token queries.

---

### Token Validation — API Gateway Authorizer (`token-authorizer/`)

On every protected API call:

1. Fetches the public JWK from the endpoint (cached in `/tmp/jwks.json` on the Lambda instance for warm reuse)
2. Verifies RS256 signature using `jwcrypto`
3. Validates all claims: `exp`, `aud` (must equal `EVENT_ID`), `iss`, `token_use`
4. Success → returns IAM policy `Effect: Allow` for the resource ARN
5. Failure → returns `Effect: Deny`

> **Note:** JWK caching in `/tmp` reduces latency and API calls on warm instances, but means key rotation is not instantaneous — cached instances will continue using the old key until the Lambda container is recycled.

---

### Session Lifecycle (`update_session.py`)

```
session_status = 0   →  active   (token issued, session in progress)
session_status = 1   →  completed (user finished successfully)
session_status = -1  →  abandoned (user left or timed out)
```

The update uses a **DynamoDB conditional write** (`ConditionExpression: session_status == 0`) to prevent double-completion races. On update:

- Increments `COMPLETED_SESSION_COUNTER` or `ABANDONED_SESSION_COUNTER` in Redis
- Publishes an event to EventBridge for downstream consumers

---

### Active Token Count (`get_num_active_tokens.py`)

Queries `TOKEN_TABLE` via `EventExpiresIndex` for records where:
- `expires >= current_time`
- `session_status == 0`

Handles DynamoDB pagination for accuracy. Used by the Max Size inlet to calculate remaining capacity.

---

## End-to-End Flow

```
User Request
    │
    ▼
SQS Queue
    │
    ▼
assign_queue_num ──► DynamoDB: { request_id, queue_position, entry_time }
                 ──► Redis: queue_counter += batch_size
    │
    ▼
Client polls get_queue_num, monitors position vs serving_counter
    │
    ▼
Inlet Strategy fires (capacity or periodic)
    └──► Redis: serving_counter += N
    └──► DynamoDB: serving_counter snapshot written
    │
    ▼
queue_position <= serving_counter?
    │
    ▼
generate_token ──► DynamoDB: token record (session_status = 0)
               ──► Secrets Manager: fetch RS256 private key
               ──► JWT: sign access + refresh + id tokens
               ──► Redis: token_counter++
    │
    ▼
Client calls protected API with JWT in Authorization header
    │
    ▼
API Gateway Lambda Authorizer
    ├── verify RS256 signature (JWK cached in /tmp)
    ├── validate claims (exp, aud, iss, token_use)
    └── return IAM Allow / Deny policy
    │
    ▼
Session ends → update_session
    ├── DynamoDB conditional write (session_status → 1 or -1)
    ├── Redis: completed_counter++ or abandoned_counter++
    └── EventBridge: session event published
```

---

## Security Considerations

| Concern | Mechanism |
|---|---|
| Input sanitisation | `deep_clean()` via `bleach` on all user input |
| Request ID validation | UUID regex pattern matching |
| Event ID validation | Must match configured `EVENT_ID` env var |
| JWT signing | RS256 with private key stored in Secrets Manager |
| Protected endpoints | IAM/SigV4 auth required |
| Token expiry | Time-based `exp` claim |
| Queue position expiry | Prevents stale positions blocking the queue |
| Race conditions | Atomic Redis increments + DynamoDB conditional writes |

---

## Notable Design Decisions

1. **Atomic Redis `INCRBY`** — batch queue assignments are a single atomic operation, eliminating position collisions under concurrent load.
2. **Pluggable inlet strategies** — the serving counter advancement is fully decoupled from the core API; strategies can be swapped or extended without touching core logic.
3. **`max()` in expiry math** — fairness guard ensuring users are not penalised for joining before a serving counter snapshot was recorded.
4. **JWK cached in `/tmp`** — reduces Secrets Manager/API calls on warm Lambda instances at the cost of slightly delayed key rotation propagation.
5. **DynamoDB conditional writes** — prevent double-token-issuance and double-session-completion without requiring distributed locks.
6. **Three-token OAuth2 pattern** — access, refresh, and ID tokens align with standard OAuth2/OIDC conventions, making integration with identity providers straightforward.

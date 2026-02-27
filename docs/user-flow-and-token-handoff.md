# User Flow & Token Handoff

> How a visitor moves from the event page to ticket purchase, and how the
> JWT is carried between sites at each stage.

---

## 1. Does a user always hit the queue?

**No.** The CloudFront Function gate checks for a `wvroom_token` cookie
**before** the request reaches the origin. If the cookie is present the user
goes straight to the buy-ticket page, skipping the queue entirely.

```
User visits ye-poland.com
        │
        ▼
CloudFront Function (edge, ~1ms)
        │
        ├─ wvroom_token cookie present? ──YES──► serve request normally
        │
        └─ NO ──► HTTP 302 → /queue/index.html
```

Three scenarios:

| Visitor type | What happens |
|---|---|
| **First visit, no cookie** | Redirected to queue. Waits for position to be served, then gets JWT and is sent to buy-ticket. |
| **Returning visitor, valid cookie** | CloudFront lets through directly. Buy-ticket page decodes the JWT and shows the purchase form. |
| **Returning visitor, expired/invalid cookie** | CloudFront Phase 1 lets through (presence check only). Buy-ticket page decodes the JWT, detects expired `exp` claim, shows "token expired — rejoin queue" screen. |

> **Phase 2 upgrade:** When the CloudFront Function is updated to do full
> RS256 signature verification (`crypto.subtle`), expired or forged tokens
> will be rejected at the edge and the user will be redirected back to the
> queue automatically.

---

## 2. Full user journey (first-time visitor)

```
1. Visit ye-poland.com
        │  no wvroom_token cookie
        ▼
2. CloudFront Function → 302 /queue/index.html
        │
        ▼
3. Queue page loads
   └─ tryResume(): checks sessionStorage for saved {requestId, myPosition}
      ├─ found (page refresh) → resume polling, skip step 4
      └─ not found → go to step 4

4. POST /assign_queue_num  {event_id}
   └─ response: {api_request_id: "..."}
        │
        ▼
5. GET /queue_num?event_id=&request_id=   (retries on HTTP 202 — SQS async)
   └─ response: {queue_number: N}   → user's position in queue
        │
        ▼
6. Save {requestId, myPosition, eventId} → sessionStorage (for refresh resume)

7. Poll every 3s:
   ├─ GET /serving_num  → current counter (how far the queue has advanced)
   ├─ GET /waiting_num  → how many people are ahead
   └─ Linear regression over samples → estimated wait time

8. When serving_counter >= myPosition:
        │
        ▼
9. POST /generate_token  {event_id, request_id}
   └─ response: {access_token: "<JWT>", ...}

10. Token storage — three mechanisms written simultaneously:
    ├─ sessionStorage.setItem('wvroom_token', jwt)   ← same-origin reload
    ├─ document.cookie = 'wvroom_token=<jwt>; path=/; SameSite=Lax'
    │   └─ CloudFront gate reads this on future visits to ye-poland.com
    └─ URL param ?wvroom_token=<encoded_jwt>         ← primary cross-domain

11. Auto-redirect after 3s (or user clicks "Proceed to checkout"):
    window.location.href = BUY_TICKET_URL + '?wvroom_token=<jwt>'
        │
        ▼
12. Buy-ticket page:
    ├─ Reads token (priority order: URL param → sessionStorage → cookie)
    ├─ Strips ?wvroom_token from URL bar (replaceState — keeps URL clean)
    ├─ Persists token to sessionStorage for reload resilience
    ├─ Decodes JWT payload (base64url — NOT cryptographic, UX only)
    ├─ Checks exp: if expired → show "token expired" screen
    ├─ Checks aud == EVENT_ID: if mismatch → show "wrong event" screen
    └─ Valid → show purchase form (ticket type, quantity, Buy button)

13. On successful purchase:
    ├─ sessionStorage.removeItem('wvroom_token')
    └─ document.cookie = 'wvroom_token=; max-age=0'   (clear cookie)
```

---

## 3. Token handoff mechanics — dev vs prod

The queue page (`ye-poland.com`) and the buy-ticket page (`buy.ye-poland.com`)
are on **different origins in production**. Cookies are origin-scoped by
default, so three mechanisms are used in combination:

### 3a. URL query parameter `?wvroom_token=<jwt>`

The primary handoff method. Always works regardless of origin or environment.
The buy-ticket page reads it first, then removes it from the URL bar with
`replaceState` so it doesn't appear in browser history or get bookmarked.

```
queue page          →  302  buy.ye-poland.com/buy-ticket?wvroom_token=<jwt>
buy-ticket page     reads param, stores in sessionStorage, cleans URL
```

**Works in:** dev and prod.

### 3b. `sessionStorage` (same-origin resilience)

After the buy-ticket page reads the URL param, it writes the token to
`sessionStorage`. On page reload — when the URL param is gone — the token
is still available.

**Works in:** same-origin reloads only (not shared across subdomains).

### 3c. Cookie `wvroom_token`

The queue page sets:
```
document.cookie = 'wvroom_token=<jwt>; path=/; SameSite=Lax'
```

No explicit `domain=` is set. Browser behaviour:

| Environment | Cookie domain | Readable by | Notes |
|---|---|---|---|
| **Dev** | `des8t03j9cqvz.cloudfront.net` | Same CloudFront distribution | Both pages on same origin — cookie shared ✅ |
| **Prod** | `ye-poland.com` | `ye-poland.com` only | CloudFront Function on ye-poland.com can read it ✅ |
| **Prod** | `ye-poland.com` | `buy.ye-poland.com` | ❌ Different subdomain — cookie NOT shared |

**Prod implication:** The cookie is enough for the CloudFront gate to recognise
a returning visitor on `ye-poland.com`. However, `buy.ye-poland.com` (Amplify)
cannot read it directly — it relies on the URL param (first visit) or
`sessionStorage` (reload).

> **To share the cookie with `buy.ye-poland.com`**, update the queue page
> for prod to set `domain=.ye-poland.com`:
> ```javascript
> document.cookie = `wvroom_token=${token}; path=/; domain=.ye-poland.com; SameSite=Lax`;
> ```
> This would allow buy.ye-poland.com to fall back to the cookie even after
> a hard reload where sessionStorage is empty. Not required for Phase 1 since
> the URL param always carries the token on the initial redirect.

---

## 4. Session resume (queue page refresh)

If a user refreshes the queue page they do **not** lose their place.

On boot, `tryResume()` checks `sessionStorage` for a saved state object:
```json
{ "requestId": "fb2ac1fd-...", "myPosition": 4, "eventId": "ye-poland-2026-04" }
```

If found and `eventId` matches `CONFIG.EVENT_ID`, the page skips
`/assign_queue_num` entirely and resumes polling from the saved position.
The `requestId` remains valid in DynamoDB — the position is not lost.

The state is saved to `sessionStorage` once both `requestId` and `myPosition`
are known (after steps 4–5 above).

---

## 5. What the CloudFront gate does and does not check

### Phase 1 (current)

```javascript
// Only checks presence — not validity, expiry, or signature
var token = cookies['wvroom_token'] ? cookies['wvroom_token'].value : null;
if (!token) { redirect to /queue/index.html }
```

| Check | Phase 1 | Phase 2 |
|---|---|---|
| Cookie present | ✅ | ✅ |
| Signature valid (RS256) | ❌ | ✅ |
| Token not expired | ❌ | ✅ |
| `aud` matches event | ❌ | ✅ |

Phase 1 is sufficient as a bot/mass-redirect defence — it stops the 99% case
(no token at all). An attacker could set an arbitrary cookie value and bypass
the gate, but they would still hit the buy-ticket page's client-side check
(wrong format → "Token could not be parsed") and eventually the AppSync Lambda
Authorizer in Phase 2.

### Phase 2 upgrade path

```javascript
// Embed public key from GET /public_key?event_id=<id> at deploy time.
// Use crypto.subtle (available in cloudfront-js-2.0) for RS256 verification.
const PUBLIC_KEY_JWK = { /* paste output of GET /public_key */ };

async function handler(event) {
  // ... import key, verify signature, check exp ...
}
```

> Key rotation note: if `reset_initial_state` is called (new RSA keypair
> generated), the embedded public key in the CloudFront Function becomes
> stale. The function must be updated and republished after any key rotation.

---

## 6. Token contents (JWT claims)

```json
{
  "alg": "RS256",
  "kid": "<key-id>",
  "typ": "JWT"
}
{
  "aud": "ye-poland-2026-04",     ← event ID — validated by buy-ticket page
  "exp": 1772190965,              ← Unix timestamp (stack ValidityPeriod=3600)
  "iat": 1772187365,
  "iss": "https://<private-api>.execute-api.eu-west-1.amazonaws.com/api",
  "nbf": 1772187365,
  "queue_position": 4,            ← user's assigned position
  "sub": "fb2ac1fd-...",          ← request_id from assign_queue_num
  "token_use": "access"
}
```

The `exp` claim is checked client-side by the buy-ticket page (UX feedback).
It is checked cryptographically by the API Gateway Lambda Authorizer when
calling the private API, and will be checked by the AppSync Lambda Authorizer
(Phase 2) when calling `buyTicket`.

---

## 7. Queue position expiry

A separate mechanism handles users who receive a position but never claim
their token (abandoned browsers, dropped connections):

- `QueuePositionExpiryPeriod = 900s` (15 min) — position expires if no token
  is generated within this window
- `IncrSvcOnQueuePositionExpiry = true` — expired positions auto-advance the
  serving counter, so the slot is not wasted
- Governed by the `SetQueuePositionExpired` Lambda triggered by an EventBridge
  rule (already running in the main stack)

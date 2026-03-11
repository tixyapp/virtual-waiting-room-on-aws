# Tester Manual — Tixy Virtual Waiting Room (Dev)

> **Environment:** `dev` — AWS profile `tixy-dev`, region `eu-west-1`  
> **Static site:** `https://des8t03j9cqvz.cloudfront.net`  
> **Public API:** `https://d3j12ztg52wyqw.cloudfront.net`  
> **Event ID:** `ye-poland-2026-04`

---

## 1. How It Works (in 2 minutes)

When a user visits the queue page, this happens:

```
1. POST /assign_queue_num   → backend assigns a position number (#1, #2, #3…)
                               (async via SQS — may return 202, retried automatically)
2. GET  /queue_num          → confirms the assigned position
3. GET  /serving_num        → polls every 3 s — the "now serving" counter
4. GET  /waiting_num        → polls every 3 s — how many people are ahead globally

When serving_counter >= your_position:
5. POST /generate_token     → issues a signed JWT (RS256, 1-hour TTL)
6. Redirect to buy-ticket URL with ?wvroom_token=<jwt>
```

**The serving counter** is the core mechanism. It advances by `INCREMENT_BY` (default: 500) every minute via an AWS EventBridge-triggered Lambda called **PeriodicInlet**. Everyone whose position number is ≤ the serving counter gets a token immediately.

**Key point:** the serving counter advances unconditionally — it does not care how many people are in the queue. If only 5 people joined but the rule ran for 6 minutes, the counter will show 3,000.

---

## 2. Prerequisites

Install these tools before running any scripts:

```bash
pip install awscurl          # IAM-signed API calls to the private endpoint
brew install awscli          # AWS CLI (if not already installed)
```

**Load the dev environment** — run this at the start of every session:

```bash
source virtual-waiting-room-on-aws/.env.dev
```

You should see: `✓ dev env loaded — profile=tixy-dev  event=ye-poland-2026-04  stack=ye-poland-waiting-room-dev`

All scripts in `scripts/` require these env vars. Never run them without sourcing first.

---

## 3. Two Operating Modes

### Mode A — Manual (one-shot advance)

The serving counter stays frozen until you explicitly move it forward.  
Use this for **step-by-step functional testing**.

```bash
# Advance the serving counter by N positions (one shot)
./virtual-waiting-room-on-aws/scripts/advance-serving.sh <N>

# Examples:
./virtual-waiting-room-on-aws/scripts/advance-serving.sh 1    # let exactly 1 person through
./virtual-waiting-room-on-aws/scripts/advance-serving.sh 500  # let 500 through at once
```

The counter moves once and stops. Call again to move it further.

### Mode B — Pre-sale (automatic, continuous)

The EventBridge rule fires every minute and calls `increment_serving_counter` automatically.  
Use this for **load testing and realistic flow simulation**.

```bash
# Start automatic admission
./virtual-waiting-room-on-aws/scripts/pre-sale.sh

# Stop it when done
./virtual-waiting-room-on-aws/scripts/close-queue.sh
```

Rate is controlled by `INCREMENT_BY` in `.env.dev` (currently `500` users/minute).

---

## 4. Start / Stop / Reset Reference

### Start the queue (begin admitting users)

```bash
source virtual-waiting-room-on-aws/.env.dev
./virtual-waiting-room-on-aws/scripts/pre-sale.sh
```

This:
1. Verifies both CloudFormation stacks are healthy
2. Sets `EVENT_ID` and `INCREMENT_BY` on the PeriodicInlet Lambda
3. Enables the EventBridge rule → counter starts advancing every minute
4. Prints current counters (should both be 0 before a clean test)

### Stop the queue (end the sale)

```bash
./virtual-waiting-room-on-aws/scripts/close-queue.sh
```

This disables the EventBridge rule. The counter freezes at its current value. Users already issued a token can still use it; no new users are admitted past the current position.

### Reset counters (same event ID — for re-testing)

Resets the serving counter and queue counter back to 0 without changing the event ID or stack config. Use between test runs.

```bash
source virtual-waiting-room-on-aws/.env.dev

awscurl \
  --service execute-api \
  --region "$REGION" \
  --profile "$PROFILE" \
  -X POST "${PRIVATE_API_URL}/reset_initial_state" \
  -H "Content-Type: application/json" \
  -d "{\"event_id\": \"${EVENT_ID}\"}"

# Expected response: {"response": "success"}
```

After reset the serving counter is 0. New users entering the queue will start from position #1.  
**Note:** old DynamoDB queue records from previous runs persist — each browser tab that enters fresh will get the next available position number, not necessarily #1.

### Full reset for a new event ID

Only needed when switching to a completely new `EVENT_ID` (e.g. a different concert). Takes ~3 minutes.

```bash
EVENT_ID=ye-poland-2026-05 ./virtual-waiting-room-on-aws/scripts/new-event.sh
```

### Monitor live queue state

```bash
# Single snapshot
./virtual-waiting-room-on-aws/scripts/queue-status.sh

# Live — refreshes every 10 seconds (Ctrl-C to stop)
./virtual-waiting-room-on-aws/scripts/queue-status.sh --watch 10
```

Output:
```
──────────────────────────────────────────────
 Queue Status — ye-poland-2026-04
 Fri Feb 27 16:30:00 CET 2026
──────────────────────────────────────────────
  Now serving : #1500
  In queue    : 243 people
  Inlet rate  : 500 / min
  Est. clear  : ~0 min at current rate
──────────────────────────────────────────────
```

---

## 5. Browser Testing — Clean State Tips

The queue page saves state in `sessionStorage` keyed to `wvroom_state`. On reload it **resumes** the old position rather than re-joining. This is intentional for real users but causes confusion during testing.

**Always use an incognito / private window for manual testing.** Each incognito session starts with empty sessionStorage.

If you want to force a fresh start in the same browser tab:

```js
// Paste in DevTools console, then reload
sessionStorage.removeItem('wvroom_state'); location.reload();
```

---

## 6. Test Scenarios

### Scenario 1 — Basic happy path (manual mode)

Verify a single user can enter the queue, get admitted, and land on the buy-ticket page.

```
1. source .env.dev
2. Reset counters: POST /reset_initial_state
3. Open https://des8t03j9cqvz.cloudfront.net/queue/index.html in incognito
4. Observe: status "Waiting in queue", YOUR NUMBER = #1, NOW SERVING = #0
5. Run: ./scripts/advance-serving.sh 1
6. Within 3–6 seconds (next poll): status changes to "It's your turn!", button turns green
7. Click "Proceed to checkout →"
8. Verify: browser lands on /buy-ticket/index.html, token is decoded, form is shown
```

**Pass criteria:** Token decoded successfully, `aud` claim matches `EVENT_ID`, `exp` is ~1 hour in the future.

---

### Scenario 2 — Queue order (multiple users)

Verify position ordering is correct and users are admitted in order.

```
1. Reset counters
2. Open 3 incognito tabs, each loads the queue page
   → Tab A gets #1, Tab B gets #2, Tab C gets #3
3. Run: ./scripts/advance-serving.sh 1
   → Only Tab A (position #1) should get "It's your turn!"
   → Tabs B and C stay waiting, AHEAD OF YOU decreases
4. Run: ./scripts/advance-serving.sh 1
   → Tab B gets admitted
5. Run: ./scripts/advance-serving.sh 1
   → Tab C gets admitted
```

**Pass criteria:** Tabs are admitted strictly in order; no tab jumps the queue.

---

### Scenario 3 — Pre-sale automatic flow

Verify the EventBridge rule advances the counter automatically at the configured rate.

```
1. Reset counters
2. Open 5 incognito tabs (positions #1–#5)
3. Run: ./scripts/pre-sale.sh
4. Monitor: ./scripts/queue-status.sh --watch 5
5. Within ~1 minute the serving counter jumps by 500
6. All 5 tabs should show "It's your turn!" within 1–2 poll cycles (3–6 seconds)
7. Run: ./scripts/close-queue.sh when done
```

**Pass criteria:** All tabs admitted within 2 minutes of enabling the inlet. Counter increments of exactly 500 visible in queue-status output.

---

### Scenario 4 — Session resume

Verify a user who refreshes the page does not lose their position.

```
1. Reset counters
2. Open incognito tab → gets position #1
3. Hard-refresh the page (Cmd+Shift+R)
4. Observe: status shows "Resuming your place…", same position #1
5. Advance serving counter by 1
6. Page detects admission and shows green button
```

**Pass criteria:** Position preserved after refresh; user does not get a new higher number.

---

### Scenario 5 — Token expiry / invalid token

Verify the buy-ticket page rejects expired or malformed tokens.

```
1. Visit: https://des8t03j9cqvz.cloudfront.net/buy-ticket/index.html?wvroom_token=FAKE
   → Should show "Invalid or expired token" error, not the purchase form
2. Get a real token via Scenario 1
3. Modify the token (change last character) and paste into the URL
   → Should show "Invalid or expired token"
```

**Pass criteria:** No purchase form shown without a valid token.

---

### Scenario 6 — Load test: queue entry throughput (Artillery)

Simulate many users arriving simultaneously and joining the queue.

**`artillery-join-queue.yml`:**

```yaml
config:
  target: "https://d3j12ztg52wyqw.cloudfront.net"
  phases:
    - duration: 60
      arrivalRate: 100       # 100 new users/second for 60 seconds = 6,000 users
  defaults:
    headers:
      Content-Type: application/json

scenarios:
  - name: "Join queue"
    flow:
      - post:
          url: "/assign_queue_num"
          json:
            event_id: "ye-poland-2026-04"
          capture:
            - json: "$.api_request_id"
              as: requestId
      - think: 1
      - get:
          url: "/queue_num?event_id=ye-poland-2026-04&request_id={{ requestId }}"
          expect:
            - statusCode:
                - 200
                - 202   # 202 = still processing, acceptable
```

Run:
```bash
artillery run artillery-join-queue.yml
```

**Watch counters in parallel:**
```bash
./virtual-waiting-room-on-aws/scripts/queue-status.sh --watch 5
```

**Pass criteria:**
- p99 response time for `/assign_queue_num` < 2 s
- No 5xx errors
- `waiting_num` counter increases proportionally to the load

---

### Scenario 7 — Load test: polling endpoints (CloudFront cache)

The `/serving_num` and `/waiting_num` endpoints have a 3-second CloudFront cache (TTL=3s, cache key = `event_id`). This scenario verifies the cache absorbs the polling load.

**`artillery-polling.yml`:**

```yaml
config:
  target: "https://d3j12ztg52wyqw.cloudfront.net"
  phases:
    - duration: 120
      arrivalRate: 500       # 500 virtual users polling simultaneously
  defaults:
    headers:
      Accept: application/json

scenarios:
  - name: "Poll serving counter"
    flow:
      - loop:
          - get:
              url: "/serving_num?event_id=ye-poland-2026-04"
              expect:
                - statusCode: 200
                - hasProperty: serving_counter
          - think: 3
        count: 10

  - name: "Poll waiting counter"
    flow:
      - loop:
          - get:
              url: "/waiting_num?event_id=ye-poland-2026-04"
              expect:
                - statusCode: 200
                - hasProperty: waiting_num
          - think: 3
        count: 10
```

**Verify cache is working** — check response headers for `x-cache: Hit from cloudfront`:

```bash
curl -sI "https://d3j12ztg52wyqw.cloudfront.net/serving_num?event_id=ye-poland-2026-04" \
  | grep -i x-cache
# Expected on 2nd+ request: x-cache: Hit from cloudfront
```

**Pass criteria:**
- `x-cache: Hit from cloudfront` on repeated requests
- p99 latency < 100 ms (cache hit) for polling endpoints
- Zero 5xx errors at 500 concurrent pollers

---

### Scenario 8 — Full end-to-end load test (Artillery)

Simulates the complete real-world flow: join queue → poll until admitted → generate token.

> **Setup:** Run `pre-sale.sh` first so the serving counter advances automatically during the test.

**`artillery-e2e.yml`:**

```yaml
config:
  target: "https://d3j12ztg52wyqw.cloudfront.net"
  phases:
    - duration: 60
      arrivalRate: 50        # 50 new users/second
  defaults:
    headers:
      Content-Type: application/json

scenarios:
  - name: "Full queue flow"
    flow:
      # Step 1: join the queue
      - post:
          url: "/assign_queue_num"
          json:
            event_id: "ye-poland-2026-04"
          capture:
            - json: "$.api_request_id"
              as: requestId

      # Step 2: wait for position assignment (SQS async — may need retries)
      - think: 2
      - get:
          url: "/queue_num?event_id=ye-poland-2026-04&request_id={{ requestId }}"
          capture:
            - json: "$.queue_number"
              as: myPosition

      # Step 3: poll serving counter (simulates 3s poll × up to 20 times)
      - loop:
          - get:
              url: "/serving_num?event_id=ye-poland-2026-04"
              capture:
                - json: "$.serving_counter"
                  as: servingNow
          - think: 3
        whileTrue: "servingNow < myPosition"
        count: 20

      # Step 4: generate token
      - post:
          url: "/generate_token"
          json:
            event_id: "ye-poland-2026-04"
            request_id: "{{ requestId }}"
          expect:
            - statusCode: 200
            - hasProperty: token
```

**Pass criteria:**
- All users receive a token within the expected wait time
  (`queue_depth / INCREMENT_BY` minutes, e.g. 3,000 users / 500/min = 6 minutes)
- p99 token generation latency < 1 s
- Zero 5xx responses throughout

---

## 7. Checklist — Before Each Test Run

```
[ ] source virtual-waiting-room-on-aws/.env.dev
[ ] Reset counters: POST /reset_initial_state
[ ] Verify reset: ./scripts/queue-status.sh  (both counters = 0)
[ ] Use incognito window for any browser-based tests
[ ] For pre-sale mode tests: run ./scripts/pre-sale.sh
[ ] After test: run ./scripts/close-queue.sh to stop the inlet
```

---

## 8. Quick Command Reference

| Action | Command |
|--------|---------|
| Load env | `source virtual-waiting-room-on-aws/.env.dev` |
| Reset counters | `awscurl ... POST /reset_initial_state` (see Section 4) |
| Start auto-admit | `./scripts/pre-sale.sh` |
| Advance manually by N | `./scripts/advance-serving.sh <N>` |
| Stop auto-admit | `./scripts/close-queue.sh` |
| Live queue monitor | `./scripts/queue-status.sh --watch 10` |
| Upload changed pages | `./scripts/upload-static-pages.sh` |
| Check CloudFront cache | `curl -sI ".../serving_num?event_id=..." \| grep x-cache` |
| Clear browser session | `sessionStorage.removeItem('wvroom_state'); location.reload()` |

---

## 9. Key Gotchas

| Gotcha | Explanation |
|--------|-------------|
| "Resuming your place…" on reload | Page reuses `sessionStorage`. Use incognito or clear manually. |
| Counter jumps to 3,000 with 5 users | Expected — inlet advances by 500/min unconditionally. Queue depth doesn't cap it. |
| `/queue_num` returns 202 | SQS is still processing the assignment. The page retries automatically. Not an error. |
| `advance-serving.sh` doesn't keep running | It's a one-shot call. For continuous advancement, use `pre-sale.sh`. |
| Old positions accumulate after reset | `reset_initial_state` resets counters but not DynamoDB records. New sessions get the next available slot, not #1. |
| CloudFront cache on polling endpoints | `serving_num` and `waiting_num` are cached for 3 s. Don't expect sub-second propagation in assertions. |
| Pre-sale starts with stale counters | Always reset before `pre-sale.sh` if re-testing. The script warns if serving counter ≠ 0. |

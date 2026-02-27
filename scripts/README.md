# Admin Scripts — Virtual Waiting Room

Operational scripts for managing the waiting room across its lifecycle.
Each script reads AWS credentials and stack names from **environment variables**
so the same scripts work for dev and prod without edits.

---

## Prerequisites

### 1. Environment variables

All scripts read AWS credentials and config from **environment variables**.
The repo ships two env files at the root:

| File | Purpose | Committed? |
|------|---------|-----------|
| `.env.example` | Blank template — copy to create your own | ✅ Yes |
| `.env.dev` | Dev environment with all values filled in | ❌ No (gitignored) |
| `.env.prod` | Prod environment (create when needed) | ❌ No (gitignored) |

**At the start of every session, source the right file:**

```bash
source .env.dev    # dev
source .env.prod   # prod
```

You'll see a confirmation line:
```
✓ dev env loaded — profile=tixy-dev  event=ye-poland-2026-04  stack=ye-poland-waiting-room-dev
```

**To create a prod env file:**
```bash
cp .env.example .env.prod
# then fill in PROFILE=tixy-prod, STACK_NAME, endpoints, etc.
```

### 2. AWS CLI profiles

Profiles `tixy-dev` and `tixy-prod` must be configured:
```bash
aws configure list-profiles   # should show tixy-dev, tixy-prod
```

### 3. `awscurl` (for IAM-authenticated private API calls)

`advance-serving.sh` and `new-event.sh` call the **private API** which
requires AWS SigV4 signing. Install once:
```bash
pip install awscurl
awscurl --version   # verify
```

---

## Scripts

| Script | When to run | Auth needed |
|--------|-------------|-------------|
| [`new-event.sh`](#new-eventsh) | Between sales — reset state + new event ID | IAM (awscurl) |
| [`pre-sale.sh`](#pre-salesh) | ~10 min before sale opens | AWS CLI |
| [`queue-status.sh`](#queue-statussh) | Anytime during a sale | Public API (curl) |
| [`advance-serving.sh`](#advance-servingsh) | Testing / emergency admission | IAM (awscurl) |
| [`close-queue.sh`](#close-queuesh) | When sale ends or sells out | AWS CLI |
| [`upload-static-pages.sh`](#upload-static-pagessh) | After editing queue/buy-ticket HTML | AWS CLI |

---

## Sale day timeline

```
T-24h   Update EVENT_ID in env vars if this is a new event.
        Run new-event.sh if reusing the stack.

T-10min Run pre-sale.sh
        └─ Sets inlet rate, enables the counter, health-checks.

T-0     Open the sale. Announce the queue URL.
        Queue page automatically handles everyone.

T+0..N  Monitor with queue-status.sh --watch 30
        Use advance-serving.sh if you need to admit people faster.

T+end   Run close-queue.sh when tickets sell out or sale closes.
```

---

## Script reference

### `new-event.sh`

Prepares the stack for a **fresh sale**. Run this when you're reusing the
same deployed stack for a different concert / date.

**What it does:**
1. Calls `POST /reset_initial_state` to zero all Redis counters
2. Updates `EventId` in the main CloudFormation stack (propagates to all core-api Lambdas, ~2-3 min)
3. Updates `EventId` in the inlet stack (~2-3 min)
4. Prints a checklist of remaining manual steps (update queue page CONFIG, upload)

**Requires:** `awscurl` (private API IAM auth)

```bash
# Set EVENT_ID to the NEW event before running:
EVENT_ID=ye-poland-2026-05 ./scripts/new-event.sh

# Or if already set in your env:
./scripts/new-event.sh
```

> ⚠ This **irreversibly resets** the queue counters. All in-progress queue
> positions for the old event will be lost. Run only between sales, never
> while a sale is active.

**After running:**
1. Update `EVENT_ID` in `source/sample-static-pages/queue/index.html`
2. Upload: `./scripts/upload-static-pages.sh queue`
3. Run `pre-sale.sh` when ready to open

---

### `pre-sale.sh`

Enables the queue. Run ~10 minutes before tickets go on sale.

**What it does:**
1. Verifies both stacks are in `CREATE_COMPLETE` / `UPDATE_COMPLETE`
2. Updates the PeriodicInlet Lambda with `EVENT_ID` and `INCREMENT_BY`
3. Enables the EventBridge rule so the serving counter starts at `rate(1 minute)`
4. Checks that counters are at zero — warns if not

```bash
./scripts/pre-sale.sh
```

**Key output:**
```
  ✓ ye-poland-waiting-room-dev → UPDATE_COMPLETE
  ✓ ye-poland-inlet-dev → UPDATE_COMPLETE
  ✓ Lambda: ye-poland-inlet-dev-PeriodicInlet-X4haPkT2H8TB
  ✓ Inlet rate: 500 users/min
  ✓ Rule enabled: ye-poland-inlet-dev-PeriodicInletRule-U4hJVCADJGph
  serving_counter : 0
  waiting_num     : 0
 READY. Sale can open now.
```

---

### `queue-status.sh`

Live snapshot of queue state. Safe to run any number of times.

```bash
./scripts/queue-status.sh              # single snapshot
./scripts/queue-status.sh --watch 30  # refresh every 30s (Ctrl-C to stop)
./scripts/queue-status.sh --watch 10  # refresh every 10s for high-traffic
```

**Output:**
```
──────────────────────────────────────────────
 Queue Status — ye-poland-2026-04
 Fri Feb 27 11:30:00 CET 2026
──────────────────────────────────────────────
  Now serving : #1509
  In queue    : 4823 people
  Inlet rate  : 500 / min
  Est. clear  : ~9 min at current rate
──────────────────────────────────────────────
```

---

### `advance-serving.sh`

Manually advances the serving counter by N positions.

**When to use:**
- **Testing:** move through the queue without waiting for the 1-min EventBridge tick
- **Emergency:** admit a burst of users (e.g. a batch of VIPs, or if the inlet fired late)
- **Recovery:** if the EventBridge rule was accidentally disabled mid-sale

**Requires:** `awscurl` (private API IAM auth)

```bash
./scripts/advance-serving.sh 10      # advance by 10 (testing)
./scripts/advance-serving.sh 500     # advance by 500 (one inlet tick equivalent)
ADVANCE_BY=100 ./scripts/advance-serving.sh
```

**Output:**
```
  Current serving counter : #1509
  Advancing by            : +10
  API response            : {"serving_num": 1519}
  New serving counter     : #1519
  Remaining in queue      : 4813
```

---

### `close-queue.sh`

Stops the inlet when the sale ends or tickets sell out.

**What it does:**
- Disables the EventBridge rule — counter stops advancing
- Users already in the queue (position ≤ current serving counter) can still
  claim their token for `QueuePositionExpiryPeriod` seconds (default 15 min)
- Users whose position has not been reached yet will see their wait time freeze

```bash
./scripts/close-queue.sh
```

**Output:**
```
──────────────────────────────────────────────
 CLOSING QUEUE — ye-poland-2026-04
──────────────────────────────────────────────
  ✓ Rule disabled: ye-poland-inlet-dev-PeriodicInletRule-...
  Final serving counter : #2500
  Remaining in queue    : 127 (will not be served)
 Sale closed. Inlet stopped.
──────────────────────────────────────────────
```

---

### `upload-static-pages.sh`

Uploads HTML pages to S3 and creates a CloudFront invalidation.

```bash
./scripts/upload-static-pages.sh              # both pages
./scripts/upload-static-pages.sh queue        # queue page only
./scripts/upload-static-pages.sh buy-ticket   # buy-ticket page only
```

Changes are live within ~60 seconds after the invalidation propagates.

> Always run this after editing the `CONFIG` block in either HTML file.

---

## Troubleshooting

### "missing required env vars"
You haven't sourced your environment file. Run:
```bash
# copy Section 0 from deployment-strategy-prompt.md into a local file:
source env-dev.sh
```

### `awscurl: command not found`
```bash
pip install awscurl
# or
pip3 install awscurl
```

### `pre-sale.sh` warns "serving counter is NOT zero"
The stack has leftover state from a previous sale. Before a fresh sale, run:
```bash
./scripts/new-event.sh
```

### EventBridge rule fires but counter doesn't advance
Check the PeriodicInlet Lambda logs:
```bash
aws logs tail /aws/lambda/$(aws cloudformation describe-stack-resource \
  --stack-name $INLET_STACK_NAME \
  --logical-resource-id PeriodicInlet \
  --profile $PROFILE --region $REGION \
  --query "StackResourceDetail.PhysicalResourceId" --output text) \
  --follow --profile $PROFILE --region $REGION
```

### `reset_initial_state` returns unexpected response
This call hits the **private API** which requires IAM auth via SigV4.
Make sure your `$PROFILE` has `execute-api:Invoke` permission on the
private API Gateway resource.

### CloudFront invalidation created but old page still shows
Invalidation typically takes 30–60 seconds. Wait and hard-refresh
(`Cmd+Shift+R` / `Ctrl+Shift+R`).

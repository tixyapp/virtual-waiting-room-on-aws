# _Deployment Strategy Prompt — Virtual Waiting Room for Tixy / ye-poland.com_

> **_How to use this file:_**  
> _Paste its full contents at the start of a new AI conversation to give complete context
> for any deployment, configuration, or development task on this project._  
> _Run the **Environment Setup** block (Section 0) first — it sets the_ `$PROFILE` _variable
> used by every script in this document._

---

## _0. Environment Setup — Run This First_

**_At the start of every session, run exactly ONE of the two blocks below._**  
_All AWS CLI commands throughout this document use_ `$PROFILE`_,_ `$REGION`_, and_ `$STACK_NAME` _set here._

```bash
# ── DEV ────────────────────────────────────────────────────────────────────
ENV=dev
PROFILE=tixy-dev
STACK_NAME=ye-poland-waiting-room-dev
INLET_STACK_NAME=ye-poland-inlet-dev

# ── PROD ───────────────────────────────────────────────────────────────────
# ENV=prod
# PROFILE=tixy-prod
# STACK_NAME=ye-poland-waiting-room-prod
# INLET_STACK_NAME=ye-poland-inlet-prod

# ── Shared (same for both envs) ────────────────────────────────────────────
REGION=eu-west-1
BUILD_BUCKET=tixy-wvroom           # S3 bucket base name (bucket = $BUILD_BUCKET-$REGION)
SOLUTION_NAME=virtual-waiting-room-on-aws
VERSION=v1.1.12

# ── Per-sale (update before each new event) ────────────────────────────────
EVENT_ID=ye-poland-2026-04         # unique slug per sale
INCREMENT_BY=500                   # users admitted per minute (tickets / sale_duration_minutes)

# ── Inlet stack (deployed separately from main stack) ──────────────────────
# Stack: ye-poland-inlet-dev   (ye-poland-inlet-prod for prod)
# Lambda: ye-poland-inlet-dev-PeriodicInlet-X4haPkT2H8TB
# Rule:   ye-poland-inlet-dev-PeriodicInletRule-U4hJVCADJGph  (rate: 1 min)

# ── Set after first deploy (from CloudFormation Outputs) ───────────────────
# DEV — deployed 2026-02-27
PUBLIC_API_URL="https://d3j12ztg52wyqw.cloudfront.net"
PRIVATE_API_URL="https://40d1xzzke4.execute-api.eu-west-1.amazonaws.com/api"
# Static dev site (queue + buy-ticket pages hosted on S3 + CloudFront)
STATIC_SITE_URL="https://des8t03j9cqvz.cloudfront.net"
STATIC_SITE_CF_ID="E2NWJFT6PM8O1F"  # CloudFront distribution ID for the static event site
STATIC_SITE_BUCKET="ye-poland-dev-site"

# ── Convenience aliases ────────────────────────────────────────────────────
CFN="aws cloudformation --profile $PROFILE --region $REGION"
LAM="aws lambda        --profile $PROFILE --region $REGION"
EVT="aws events        --profile $PROFILE --region $REGION"
S3C="aws s3            --profile $PROFILE"
```

## IMPORTANT

## _1. Project Overview_

_We are deploying a virtual waiting room for a high-traffic ticket sale (~300k visitors on sale day) for a concert/event ticketing service._

_The waiting room is based on **AWS's open-source solution**:_  
`virtual-waiting-room-on-aws` _— a serverless queue system using API Gateway, Lambda, SQS, DynamoDB, ElastiCache (Valkey), and CloudFront._

_The codebase lives at:_  
`/Users/wojtekkinastowski/Projects/tixy/wvroom/virtual-waiting-room-on-aws/`

---

## _2. Application Stack_

### _Two separate AWS applications_

| _App_                      | _Dev URL_                           | _Prod URL_                     | _Technology_      |
| -------------------------- | ----------------------------------- | ------------------------------ | ----------------- |
| **_Static event page_**    | _CloudFront URL (TBD after deploy)_ | `ye-poland.com`                | _S3 + CloudFront_ |
| **_Ticket purchase flow_** | _Amplify URL +_ `/buy-ticket`       | `buy.ye-poland.com/buy-ticket` | _AWS Amplify_     |

_The purchase flow APIs are **AppSync GraphQL** — not REST/API Gateway._

### _Waiting room stack (this repo)_

- _Deployed as a **CloudFormation stack** from_ `deployment/virtual-waiting-room-on-aws.json`
- _Exposes a **Public REST API** (API Gateway + CloudFront) consumed by the queue page_
- _Issues **JWT tokens** (RS256, signed with a key pair in Secrets Manager) when it's a user's turn_
- _Redis counters hold the queue state; DynamoDB holds persistent position records_

---

## _3. Key Modifications Already Made to the Codebase_

_These changes are already committed in the repo. Do not re-implement them._

### _3a. ElastiCache Serverless (Valkey) migration_

**\*Why:** Provisioned Redis costs ~$252/month always-on. Valkey Serverless costs ~$6/month idle.\*

**_What was changed:_**

- `deployment/virtual-waiting-room-on-aws.json`_:_
  - _Replaced_ `AWS::ElastiCache::ReplicationGroup` _with_ `AWS::ElastiCache::ServerlessCache` _(engine:_ `valkey`_)_
  - _Added_ `AWS::ElastiCache::User` _(_`waitingroom` _user) and_ `AWS::ElastiCache::UserGroup`
  - _Updated_ `RedisAuth` _secret to generate JSON_ `{"username": "waitingroom", "password": "<generated>"}` _via Secrets Manager_ `GenerateSecretString`
  - _All_ `REDIS_HOST` _/_ `REDIS_PORT` _env vars now reference_ `RedisServerlessCache` _endpoints_
  - _Removed_ `RedisPort` _parameter and_ `SubnetGroup` _resource (not needed for Serverless)_
- `source/shared/virtual-waiting-room-on-aws-common/vwr/common/redis_client.py` _(new file):_
  - _Centralised_ `get_redis_client(secrets_client, secret_name_prefix)` _helper_
  - _Reads_ `username` _+_ `password` _from Secrets Manager JSON secret_
  - _Falls back to password-only for backwards compatibility_
- **\*12 Lambda functions** in* `source/core-api/chalicelib/`*:\*
  - _Replaced inline_ `redis.Redis(...)` _instantiation with_ `get_redis_client()` _call_
  - _Removed duplicate Secrets Manager fetch code from each function_

### _3b. Sample static pages (no Vue, no build step)_

_Two zero-dependency HTML pages created at_ `source/sample-static-pages/`_:_

| _File_                  | _Purpose_                                                                                                       |
| ----------------------- | --------------------------------------------------------------------------------------------------------------- |
| `queue/index.html`      | _The waiting room page — enters queue, polls position, shows progress, redirects with JWT when ready_           |
| `buy-ticket/index.html` | _Token-gated buy ticket page — reads JWT from URL/sessionStorage/cookie, validates expiry, shows purchase form_ |

_Both pages have a_ `CONFIG` _block at the top — the only thing to edit per deployment._

---

## _4. Architecture & Integration Design_

### _Traffic flow_

```
300k users → ye-poland.com (S3 + CloudFront)
                    │
                    ▼
       CloudFront Function (edge, JS)
       ┌── Has valid wvroom_token cookie? ──► allow through normally
       └── No token? ──────────────────────► redirect to /queue/index.html
                    │
                    ▼
       /queue/index.html  (same S3 bucket, same CloudFront distro)
       - POST /assign_queue_num    → gets requestId
       - GET  /queue_num           → gets myPosition (retries on 202)
       - GET  /serving_num  (3s)   → tracks progress
       - GET  /waiting_num  (3s)   → shows queue depth
       - Linear regression         → estimates wait time
       - POST /generate_token      → gets JWT when turn arrives
       - Sets cookie on domain     → for prod subdomain sharing
       - Redirects to BUY_TICKET_URL?wvroom_token=<jwt>
                    │
                    ▼
       buy.ye-poland.com/buy-ticket  (Amplify app)
       - Reads ?wvroom_token from URL param      ← dev + prod
       - Falls back to sessionStorage            ← same-origin reload
       - Falls back to .ye-poland.com cookie     ← prod subdomain
       - Decodes JWT client-side (UX check only, not crypto verification)
       - Checks exp, aud (event_id)
       - Calls buyTicket GraphQL mutation with token
```

### _Token handoff — dev vs prod_

| _Environment_ | _Mechanism_                                           | _Reason_                                |
| ------------- | ----------------------------------------------------- | --------------------------------------- |
| _Dev_         | _URL query param_ `?wvroom_token=<jwt>`               | _Different domains — no cookie sharing_ |
| _Prod_        | _Parent-domain cookie_ `.ye-poland.com` _+ URL param_ | `buy.` _is a subdomain, cookie works_   |

### _Waiting room page location_

_The_ `queue/index.html` _page lives **inside the same S3 bucket and CloudFront distribution** as the static event page (not a separate origin). This means:_

- _No CORS issues between event page and queue page_
- _The CloudFront Function can redirect to_ `/queue/index.html` _seamlessly_
- _The cookie set by_ `queue/index.html` _is on the same domain as the event page_

---

## _5. Authorization Strategy_

### _Phase 1 — Client-side only (ship now)_

**\*No changes to AppSync.** Protection layers:\*

1. **\*CloudFront Function** — redirects tokenless users to the queue (edge, fast, blocks bot floods)\*
2. **\*Amplify app mount check** — reads token on page load, redirects back to queue if missing/expired\*
3. _Queue still works perfectly and issues real JWTs; token is real, expiry is enforced client-side_

**\*Limitation:** A technical user who knows the AppSync endpoint could call* `buyTicket` *directly. Acceptable for dev and early prod.\*

### _Phase 2 — AppSync Lambda Authorizer (add before high-stakes sale)_

_AppSync supports multiple auth modes. Add a Lambda authorizer as a **second auth mode** on top of the existing primary auth (Cognito or API Key):_

- _Add_ `Lambda` _as additional auth mode in AppSync console / CDK / CloudFormation_
- _Annotate gated mutations in schema:_ `type Mutation { buyTicket(...): ... @aws_lambda }`
- _Write a new Lambda function that wraps the existing JWT validation logic (_`verify_token_sig`_,_ `verify_token` _from_ `source/token-authorizer/chalice/app.py`_) with the AppSync response format:_
  ```python
  def appsync_authorizer(event, _):
      token = event.get("authorizationToken", "")
      claims = verify_token(token)
      return {
          "isAuthorized": bool(claims),
          "resolverContext": {"requestId": claims.get("sub")} if claims else {},
          "ttlOverride": 0
      }
  ```
- _Amplify client sends token for gated mutations:_
  ```js
  await client.graphql({
    query: buyTicketMutation,
    variables: { ... },
    authMode: 'lambda',
    authToken: sessionStorage.getItem('wvroom_token'),
  });
  ```
- _The existing_ `api_gateway_authorizer` _function (returns IAM policy document) is for API Gateway and is **not reused** — only the_ `verify_token` _/_ `verify_token_sig` _/_ `get_public_key` _logic is reused._

**_This is fully additive — nothing built in Phase 1 needs to change._**

---

## _6. CloudFront Function (UX Gate) — Build in Phase 1_

_A lightweight JS function (_`cloudfront-js-2.0` _runtime) attached to the **default behaviour** of the **static event page CloudFront distribution**._

**\*Decision: build this in Phase 1 dev.** Reason: it's ~15 lines of JS and without it, testing is unrealistic — you'd have to manually navigate to the queue page. Building it in dev means you test the full real flow from day one. The Phase 1 version does a presence check only (no crypto), so it's trivial to write.\*

**\*Purpose:** intercept requests toward the buy path and redirect users without a valid token to the waiting room.\*

**_Constraints of CloudFront Functions:_**

- _No network calls — cannot fetch the public key at runtime_
- _The RS256 public key must be **embedded** in the function code_
- _Key rotation requires redeploying the function (rare — keys are only rotated on stack reset)_

**_Simplified Phase 1 version (checks token presence + basic expiry, no signature verification):_**

```javascript
// cloudfront-functions/gate.js
function handler(event) {
  var request = event.request;
  var cookies = request.cookies;

  // only gate the buy path, not the static event info page itself
  if (!request.uri.startsWith("/buy") && !request.uri.startsWith("/queue")) {
    return request;
  }

  var token = cookies["wvroom_token"] ? cookies["wvroom_token"].value : null;
  if (!token) {
    return {
      statusCode: 302,
      headers: { location: { value: "/queue/index.html" } },
    };
  }
  // optionally: decode and check exp claim (no crypto needed for basic check)
  return request;
}
```

**\*Phase 2 version** embeds the RS256 public key and uses* `crypto.subtle` *(Web Crypto API, available in* `cloudfront-js-2.0`*) for full signature verification.\*

---

## _7. Inlet Strategy_

_Controls how fast users are released from the queue to purchase._

_The deployed stack supports two inlet strategies:_

| _Strategy_          | _Lambda_        | _Trigger_                | _Use case_                             |
| ------------------- | --------------- | ------------------------ | -------------------------------------- |
| **_PeriodicInlet_** | `PeriodicInlet` | _EventBridge 1-min rule_ | _Advance counter by N every minute_    |
| **_MaxSizeInlet_**  | `MaxSizeInlet`  | _SNS message_            | _Advance counter when capacity allows_ |

**\*For Tixy, use PeriodicInlet.** Set* `INCREMENT_BY` *env var = number of users you want to admit per minute.\*

_Example: if the venue has 5000 tickets and you want to sell them over 30 minutes:_

- `INCREMENT_BY = 167` _(5000 / 30)_

_Pre-sale admin checklist:_

```bash
# 1. Reset queue state (clean slate for new sale)
POST {PRIVATE_API}/reset_initial_state   (IAM-authenticated)

# 2. Set INCREMENT_BY on the PeriodicInlet Lambda
#    (Lambda lives in $INLET_STACK_NAME — see Script 3 for full version)
INLET_FN=$(aws cloudformation describe-stack-resource \
  --stack-name $INLET_STACK_NAME --logical-resource-id PeriodicInlet \
  --profile $PROFILE --region $REGION \
  --query "StackResourceDetail.PhysicalResourceId" --output text)
aws lambda update-function-configuration \
  --function-name "$INLET_FN" \
  --environment "Variables={INCREMENT_BY=$INCREMENT_BY,EVENT_ID=$EVENT_ID,\
CORE_API_ENDPOINT=$PRIVATE_API_URL,CORE_API_REGION=$REGION,\
START_TIME=1626336061,END_TIME=0,CLOUDWATCH_ALARM=unused}" \
  --profile $PROFILE --region $REGION

# 3. Enable the EventBridge rule (if disabled between sales)
INLET_RULE=$(aws cloudformation describe-stack-resource \
  --stack-name $INLET_STACK_NAME --logical-resource-id PeriodicInletRule \
  --profile $PROFILE --region $REGION \
  --query "StackResourceDetail.PhysicalResourceId" --output text)
aws events enable-rule --name "$INLET_RULE" --profile $PROFILE --region $REGION
```

---

## _8. On/Off Strategy_

| _Scenario_        | _Recommended approach_                        | _Idle cost_          |
| ----------------- | --------------------------------------------- | -------------------- |
| _>2 events/month_ | _Keep stack deployed, Valkey Serverless idle_ | _~$6–15/month_       |
| _<2 events/month_ | _Deploy before sale, delete after_            | _~$0 between events_ |

_Valkey Serverless changes the economics completely — at $6/month idle, always-on is viable._

---

## _9. Build Process — REQUIRED Before First Deploy_

_The CloudFormation template (_`deployment/virtual-waiting-room-on-aws.json`_) contains_ `%%BUCKET_NAME%%`_,_ `%%VERSION%%`_, and_ `%%SOLUTION_NAME%%` _placeholders. **It cannot be deployed directly.** A build script packages Lambda functions, replaces placeholders, and uploads artifacts to S3 first._

> **_Upstream reference:_** _The original AWS build and customisation steps are documented in_ [`README.md`](../README.md) _at the repo root. This deployment strategy supersedes those instructions for the Tixy/ye-poland deployment, but the README remains the authoritative source for upstream build tooling details (Poetry version, S3 bucket naming conventions, unit-test runner)._

### _Prerequisites_

- _Python 3.12 + pip_
- _[Poetry](https://python-poetry.org/) 2.0.1 (_`pip install poetry`_)_
- _Docker (for building the JWCrypto Lambda layer)_
- _Node.js + npm (for the Vue control panel and sample site)_
- _AWS CLI configured with credentials and a target S3 bucket in the deployment region_

> **_Pre-existing virtual environment:_**  
> _A Python virtual environment already exists at_ `.venv/` _in the repository root  
> (_`/Users/wojtekkinastowski/Projects/tixy/wvroom/virtual-waiting-room-on-aws/.venv/`_)
> with all project dependencies pre-installed.  
> Activate it before running any Python tooling or unit tests:_
>
> ```bash
> source .venv/bin/activate
> ```
>
> _If you need to recreate it from scratch, follow the_ `README.md` _instructions:_
>
> ```bash
> cd deployment/
> poetry install
> ```

### _Steps_

_See **Script 1 (deploy-stack)** in the Operations Runbook (Section 14) for the full command sequence._  
_Short version:_

```bash
# Requires Section 0 environment variables to be set first.
cd deployment/
./build-s3-dist.sh $BUILD_BUCKET $SOLUTION_NAME $VERSION
AWS_PROFILE=$PROFILE ./deploy.sh -b $BUILD_BUCKET -r $REGION -a none -t dev -v $VERSION
$CFN deploy \
  --stack-name $STACK_NAME \
  --template-file global-s3-assets/virtual-waiting-room-on-aws.template \
  --s3-bucket ${BUILD_BUCKET}-${REGION} \
  --s3-prefix cfn-deploy \
  --parameter-overrides \
      EventId=$EVENT_ID \
      ValidityPeriod=3600 \
      QueuePositionExpiryPeriod=900 \
      EnableQueuePositionExpiry=true \
      IncrSvcOnQueuePositionExpiry=true \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
```

> **\*Note:** Since the ElastiCache Serverless and RBAC changes are already in the template (_`deployment/virtual-waiting-room-on-aws.json`_), the built output will include those changes automatically.\*

> **\*Inlet stack — deploy separately:** The `PeriodicInlet` Lambda and EventBridge rule live in a **second CloudFormation stack** (`$INLET_STACK_NAME`) based on `virtual-waiting-room-on-aws-sample-inlet-strategy.template`. Deploy it after the main stack:\*
>
> ```bash
> $CFN deploy \
>   --stack-name $INLET_STACK_NAME \
>   --template-file global-s3-assets/virtual-waiting-room-on-aws-sample-inlet-strategy.template \
>   --s3-bucket ${BUILD_BUCKET}-${REGION} --s3-prefix cfn-deploy \
>   --parameter-overrides \
>     EventId=$EVENT_ID \
>     PrivateCoreApiEndpoint=$PRIVATE_API_URL \
>     CoreApiRegion=$REGION \
>     InletStrategy=Periodic \
>     IncrementBy=$INCREMENT_BY \
>     StartTime=1626336061 \
>     EndTime=0 \
>     CloudWatchAlarmName=unused \
>     MaxSize=100 \
>   --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
> ```
>
> _The rule deploys as **ENABLED** — it will start firing immediately. Disable it between sales with Script 6._

### _CORS_

_The Public API has_ `Access-Control-Allow-Origin: '*'` _pre-configured for all endpoints. No additional CORS setup is needed regardless of the Amplify app's origin._

---

## _10. Build Order (Phase 1 — Dev)_

_Execute in order. Each step has a clear done-criteria._

```
Step 1 — Deploy CloudFormation stack
  - Template: deployment/virtual-waiting-room-on-aws.json
  - Parameters: EventId, AWS region, VPC CIDR etc.
  - Done: stack status CREATE_COMPLETE, API Gateway URL in outputs

Step 2 — Configure and upload queue page
  - Edit CONFIG block in source/sample-static-pages/queue/index.html
  - Upload to S3 bucket under /queue/index.html
  - Done: https://<cloudfront>/queue/index.html loads, enters queue

Step 3 — Configure buy-ticket page (Amplify)
  - Add token-check logic on /buy-ticket page mount (read from URL param)
  - Edit CONFIG in source/sample-static-pages/buy-ticket/index.html if using standalone
  - Done: visiting /buy-ticket?wvroom_token=FAKE shows "invalid token" screen

Step 4 — CloudFront Function  ← build NOW in Phase 1 dev
  - Create function in CloudFront console (cloudfront-js-2.0 runtime)
  - Attach to the static event page CloudFront distribution, default behaviour
  - Phase 1 code: ~15 lines — checks for wvroom_token cookie; if absent, redirects to /queue/index.html
  - Only gate paths that lead to purchase (e.g. anything that links to the buy URL)
  - Done: visiting static event page without token triggers redirect to /queue/

  Phase 2 upgrade (before high-stakes sale):
  - Embed RS256 public key (from GET /public_key?event_id=)
  - Add crypto.subtle signature verification
  - Add expiry check from JWT claims
  - Deploy updated function version

Step 5 — End-to-end test
  - Visit static page → redirected to queue
  - Queue page enters queue, shows position
  - Advance serving counter manually via private API or wait for PeriodicInlet
  - Token generated → redirected to buy-ticket URL with ?wvroom_token=
  - Buy-ticket page shows valid token and purchase form
  - Done: full flow works without manual intervention

--- Ship dev ---

Step 6 (Phase 2) — AppSync Lambda Authorizer
  - New Lambda function (separate from API Gateway authorizer)
  - Reuses verify_token logic from source/token-authorizer/chalice/app.py
  - AppSync response format (isAuthorized: bool)
  - Add as second auth mode on AppSync API
  - Annotate buyTicket mutation with @aws_lambda
  - Update Amplify client to pass authMode: 'lambda' for that mutation
  - Done: calling buyTicket without token returns 401, with valid token succeeds

--- Ship prod ---
```

---

## _11. Key File Locations_

| _Purpose_                            | _Path_                                                                        |
| ------------------------------------ | ----------------------------------------------------------------------------- |
| _CloudFormation template (modified)_ | `deployment/virtual-waiting-room-on-aws.json`                                 |
| _Shared Redis client helper_         | `source/shared/virtual-waiting-room-on-aws-common/vwr/common/redis_client.py` |
| _Core API Lambda functions_          | `source/core-api/chalicelib/`                                                 |
| _Token authorizer (API Gateway)_     | `source/token-authorizer/chalice/app.py`                                      |
| _Sample static waiting room page_    | `source/sample-static-pages/queue/index.html`                                 |
| _Sample buy-ticket gated page_       | `source/sample-static-pages/buy-ticket/index.html`                            |
| _Architecture + cost analysis_       | `docs/architecture-cost-and-tixy-usage.md`                                    |
| _This file_                          | `docs/deployment-strategy-prompt.md`                                          |

---

## _12. Open Parameters (fill in per deployment)_

```
AWS_REGION:                     eu-west-1  ← default; confirm at start of each deployment
BUILD_BUCKET_BASE:              <your S3 bucket base name, e.g. tixy-wvroom>
STACK_NAME:                     ye-poland-waiting-room-dev
EVENT_ID:                       <e.g. ye-poland-2026-04>  ← decide per sale
VALIDITY_PERIOD:                3600  (1 hour token TTL — default)
QUEUE_POSITION_EXPIRY_PERIOD:   900   (15 min to claim token — confirmed)
INCR_SVC_ON_EXPIRY:             true  (auto-advance on abandoned spots — confirmed)
INCREMENT_BY:                   <users to admit per minute, e.g. 167 for 5000 tickets / 30 min>
CORE_API_URL:                   <from CloudFormation Outputs: PublicApiInvokeURL>
CLOUDFRONT_URL:                 <from CloudFormation Outputs: PublicApiInvokeURL (same — it's via CF)>
PRIVATE_API_URL:                <from CloudFormation Outputs: PrivateApiInvokeURL>
BUY_TICKET_URL:                 <Amplify URL>/buy-ticket
```

---

## _13. Constraints & Gotchas_

- **\*CORS:** The Public API uses* `Access-Control-Allow-Origin: '*'` _(wildcard) — already configured in the Swagger definition. No CORS setup needed regardless of which Amplify URL you use._
- **\*Token expiry window:** Tokens have a fixed TTL set at stack deploy time. Users who don't complete purchase before expiry must re-enter the queue. Choose TTL based on how long checkout takes (e.g. 15–30 min).\*
- **\*Queue counter reuse:** Queue counters are NOT reset between sessions unless* `reset_initial_state` *is called. Always reset before a new sale.\*
- **\*CloudFront Function key rotation:** If* `reset_initial_state` *is called, new RSA keys are generated. The public key embedded in the CloudFront Function (Phase 2) must be updated manually after any key rotation.\*
- `**queue_num` _returns 202:\*\* The SQS-based queue assignment is async._ `GET /queue_num` _returns 202 until the SQS message is processed. The queue page retries with exponential back-off — this is expected behaviour._
- **\*Valkey engine:** The CloudFormation template was updated to use* `valkey` *engine on ElastiCache Serverless. The Python* `redis-py` *client works unchanged — Valkey is wire-compatible.\*
- **\*Secrets Manager dynamic reference — double-colon fix (already applied):** The* `RedisAppUser` *resource originally referenced the Redis password as* `SecretString::password` *(two colons), which CloudFormation parsed as an empty JSON key + a version-stage named* `password`*. This caused* `CREATE_FAILED` *on first deploy. Fixed to* `SecretString:password` *(single colon) in* `deployment/virtual-waiting-room-on-aws.json`*.\*
- **\*deploy.sh profile & version:** `deploy.sh` _has no_ `--profile` _flag — pass_ `AWS_PROFILE=$PROFILE` _as an env prefix. Always pass_ `-v $VERSION` _to match the version baked into the template by_ `build-s3-dist.sh`_; omitting it uploads to the wrong S3 key and causes_ `S3 key does not exist` \*errors at deploy time.\*
- **CloudFront caching for polling endpoints**
  `serving_num` and `waiting_num` return a **single global counter** identical for all users
  on the same `event_id`. By default the Public API CloudFront distribution uses
  `CachingDisabled`, so every poll (every 3 s × 300k users) hits Lambda + API Gateway —
  ~$165 per sale day wasted.

**Fix (one-time, done Feb 2026):** Created a `WaitingRoomPolling` CloudFront cache
policy (TTL = 3 s, cache key = `event_id` query string) and added two cache behaviors
ahead of the default `*` behavior:

| Path pattern    | Cache policy       | Effect                      |
| --------------- | ------------------ | --------------------------- |
| `/serving_num*` | WaitingRoomPolling | 99.9% cache hit during sale |
| `/waiting_num*` | WaitingRoomPolling | 99.9% cache hit during sale |

**For future stacks:** this is a manual post-deploy step because the CloudFormation
template's CloudFront distribution uses `CachingDisabled` by default. After deploying
a new stack, run `scripts/cf-caching-fix.sh` (or add the behaviors via Console) before
going live.

**Verify after deploy:**
curl -sI "https://<PUBLIC_API_URL>/serving_num?event_id=<EVENT_ID>" | grep x-cache

# Expected: x-cache: Hit from cloudfront (on 2nd+ request)

---

## _14. Operations Runbook_

> **_Always run Section 0 (Environment Setup) before any script below._**  
> _All scripts assume_ `$PROFILE`_,_ `$STACK_NAME`_,_ `$REGION`_,_ `$EVENT_ID`_,_ `$PUBLIC_API_URL`_,_  
> `$PRIVATE_API_URL`_, and_ `$INCREMENT_BY` _are set._

---

### _Script 1 — deploy-stack (first-time only)_

_Builds Lambda packages, uploads artifacts to S3, then deploys the CloudFormation stack._  
_Run once per environment. Takes ~15–20 min on first deploy._

```bash
# ── 1. Create artifact bucket (once per region per env) ───────────────────
$S3C mb s3://${BUILD_BUCKET}-${REGION} --region $REGION

# ── 2. Build (from repo root) ─────────────────────────────────────────────
cd deployment/
./build-s3-dist.sh $BUILD_BUCKET $SOLUTION_NAME $VERSION
# Outputs: global-s3-assets/ (template) and regional-s3-assets/ (Lambda zips)

# ── 3. Upload artifacts to S3 ─────────────────────────────────────────────
AWS_PROFILE=$PROFILE ./deploy.sh -b $BUILD_BUCKET -r $REGION -a none -t dev -v $VERSION

# ── 4. Deploy CloudFormation stack ────────────────────────────────────────
$CFN deploy \
  --stack-name $STACK_NAME \
  --template-file global-s3-assets/virtual-waiting-room-on-aws.template \
  --s3-bucket ${BUILD_BUCKET}-${REGION} \
  --s3-prefix cfn-deploy \
  --parameter-overrides \
    EventId=$EVENT_ID \
    ValidityPeriod=3600 \
    QueuePositionExpiryPeriod=900 \
    EnableQueuePositionExpiry=true \
    IncrSvcOnQueuePositionExpiry=true \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM
# Note: --s3-bucket is required because the template exceeds the 51,200-byte
#       CloudFormation inline limit. The template is staged in the artifact
#       bucket under the cfn-deploy/ prefix before deployment.

# ── 5. Capture outputs ────────────────────────────────────────────────────
$CFN describe-stacks --stack-name $STACK_NAME \
  --query "Stacks[0].Outputs" --output table

# → Set PUBLIC_API_URL and PRIVATE_API_URL from the outputs above
#   then re-run Section 0 with those values filled in
```

---

### _Script 2 — new-event (run before each sale)_

_Resets all queue counters to zero and switches the stack to a new Event ID._  
_Use this when reusing the same stack for a different concert / sale date._

```bash
# ── 1. Reset all Redis counters (clean slate) ─────────────────────────────
#    Requires awscurl (pip install awscurl)
awscurl \
  --service execute-api \
  --region $REGION \
  --profile $PROFILE \
  -X POST "${PRIVATE_API_URL}/reset_initial_state" \
  -H "Content-Type: application/json" \
  -d "{\"event_id\": \"$EVENT_ID\"}"

# Expected response: {"response": "success"}

# ── 2. Update EventId in CloudFormation (propagates to all Lambda env vars)
#    ~2–3 min; only Lambda config updates, no code redeploy ─────────────────
$CFN update-stack \
  --stack-name $STACK_NAME \
  --use-previous-template \
  --parameters \
    ParameterKey=EventId,ParameterValue=$EVENT_ID \
    ParameterKey=ValidityPeriod,UsePreviousValue=true \
    ParameterKey=QueuePositionExpiryPeriod,UsePreviousValue=true \
    ParameterKey=EnableQueuePositionExpiry,UsePreviousValue=true \
    ParameterKey=IncrSvcOnQueuePositionExpiry,UsePreviousValue=true \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM

# Wait for update to complete:
$CFN wait stack-update-complete --stack-name $STACK_NAME
echo "Stack updated. EventId is now: $EVENT_ID"

# ── 3. Update queue page config in S3 ─────────────────────────────────────
#    Edit source/sample-static-pages/queue/index.html CONFIG block first,
#    then upload:
S3_BUCKET=$($CFN describe-stack-resource \
  --stack-name $STACK_NAME \
  --logical-resource-id WaitingRoomBucket \
  --query "StackResourceDetail.PhysicalResourceId" --output text 2>/dev/null || echo "YOUR_S3_BUCKET")

$S3C cp source/sample-static-pages/queue/index.html \
  s3://${S3_BUCKET}/queue/index.html \
  --content-type "text/html"

echo "Done. New event '$EVENT_ID' is ready."
```

---

### _Script 3 — pre-sale (run ~10 min before tickets go on sale)_

_Configures the inlet rate, enables the queue, and verifies everything is healthy._

```bash
# ── 1. Verify both stacks are healthy ─────────────────────────────────────
for SNAME in $STACK_NAME $INLET_STACK_NAME; do
  STATUS=$($CFN describe-stacks --stack-name $SNAME \
    --query "Stacks[0].StackStatus" --output text)
  echo "Stack $SNAME: $STATUS"
  # Should be UPDATE_COMPLETE or CREATE_COMPLETE. Abort if anything else.
done

# ── 2. Resolve PeriodicInlet Lambda name from inlet stack ─────────────────
#    The inlet Lambda lives in $INLET_STACK_NAME, not $STACK_NAME.
INLET_FN=$($CFN describe-stack-resource \
  --stack-name $INLET_STACK_NAME \
  --logical-resource-id PeriodicInlet \
  --query "StackResourceDetail.PhysicalResourceId" --output text)
echo "Inlet Lambda: $INLET_FN"

# ── 3. Update EVENT_ID and INCREMENT_BY; preserve all other env vars ──────
#    Env var key is CORE_API_ENDPOINT (not CORE_API_URL).
CURRENT_ENV=$($LAM get-function-configuration \
  --function-name "$INLET_FN" \
  --query "Environment.Variables" --output json)

NEW_ENV=$(echo "$CURRENT_ENV" | python3 -c "
import sys, json
e = json.load(sys.stdin)
e['EVENT_ID']      = '${EVENT_ID}'
e['INCREMENT_BY']  = '${INCREMENT_BY}'
e['CORE_API_ENDPOINT'] = '${PRIVATE_API_URL}'
print('Variables=' + json.dumps(e).replace(' ',''))
")

$LAM update-function-configuration \
  --function-name "$INLET_FN" \
  --environment "$NEW_ENV"
echo "Inlet rate set to $INCREMENT_BY users/min for event $EVENT_ID"

# ── 4. Resolve and enable PeriodicInlet EventBridge rule ──────────────────
INLET_RULE=$($CFN describe-stack-resource \
  --stack-name $INLET_STACK_NAME \
  --logical-resource-id PeriodicInletRule \
  --query "StackResourceDetail.PhysicalResourceId" --output text)
$EVT enable-rule --name $INLET_RULE
echo "Inlet rule enabled: $INLET_RULE"

# ── 5. Quick health check — confirm counters are at zero ──────────────────
echo "--- Queue status at sale open ---"
curl -s "${PUBLIC_API_URL}/serving_num?event_id=${EVENT_ID}" | python3 -m json.tool
curl -s "${PUBLIC_API_URL}/waiting_num?event_id=${EVENT_ID}" | python3 -m json.tool
echo "Ready. Sale can open now."
```

---

### _Script 4 — queue-status (run anytime during a sale)_

_Live snapshot of queue depth, serving position, and throughput._

```bash
echo "============================================"
echo " Queue Status — $EVENT_ID ($ENV)"
echo " $(date)"
echo "============================================"

SERVING=$(curl -s "${PUBLIC_API_URL}/serving_num?event_id=${EVENT_ID}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['serving_counter'])")

WAITING=$(curl -s "${PUBLIC_API_URL}/waiting_num?event_id=${EVENT_ID}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['waiting_num'])")

echo "  Now serving : #$SERVING"
echo "  In queue    : $WAITING people"
echo "  Inlet rate  : $INCREMENT_BY / min"

if [ "$WAITING" -gt 0 ] && [ "$INCREMENT_BY" -gt 0 ]; then
  MINUTES=$(( WAITING / INCREMENT_BY ))
  echo "  Est. clear  : ~${MINUTES} min at current rate"
fi

echo "============================================"
```

---

### _Script 5 — advance-serving (manual step / emergency / testing)_

_Manually advances the serving counter by N positions._  
_Use during testing to move users through the queue, or in production if the
PeriodicInlet fires too slowly._

```bash
ADVANCE_BY=${1:-10}    # pass as argument, default 10
                       # e.g.: ADVANCE_BY=50 bash advance-serving.sh
                       #   or: source this script with ADVANCE_BY=50

echo "Advancing serving counter by $ADVANCE_BY for event $EVENT_ID..."

awscurl \
  --service execute-api \
  --region $REGION \
  --profile $PROFILE \
  -X POST "${PRIVATE_API_URL}/increment_serving_counter" \
  -H "Content-Type: application/json" \
  -d "{\"event_id\": \"$EVENT_ID\", \"increment_by\": $ADVANCE_BY}"

echo ""
echo "New serving position:"
curl -s "${PUBLIC_API_URL}/serving_num?event_id=${EVENT_ID}" | python3 -m json.tool
```

---

### _Script 6 — close-queue (run when sale ends or tickets sell out)_

_Stops the PeriodicInlet from advancing the counter. Users already in the queue
can still claim their tokens; no new users are admitted._

```bash
# ── 1. Disable PeriodicInlet EventBridge rule ─────────────────────────────
#    Rule lives in $INLET_STACK_NAME, not $STACK_NAME.
INLET_RULE=$($CFN describe-stack-resource \
  --stack-name $INLET_STACK_NAME \
  --logical-resource-id PeriodicInletRule \
  --query "StackResourceDetail.PhysicalResourceId" --output text)
$EVT disable-rule --name $INLET_RULE
echo "Inlet stopped. Rule disabled: $INLET_RULE"

# ── 2. Final queue snapshot ───────────────────────────────────────────────
echo "--- Final queue status ---"
SERVING=$(curl -s "${PUBLIC_API_URL}/serving_num?event_id=${EVENT_ID}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['serving_counter'])")
WAITING=$(curl -s "${PUBLIC_API_URL}/waiting_num?event_id=${EVENT_ID}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['waiting_num'])")
echo "  Final serving counter : $SERVING"
echo "  Remaining in queue    : $WAITING (will not be served)"
echo "Sale closed."
```

---

### _Script 7 — teardown-stack_

_Deletes the entire CloudFormation stack. Use for dev cleanup or Option 2_  
\*(deploy-before/teardown-after) cost strategy. **Irreversible.\***

```bash
echo "WARNING: This will delete stack '$STACK_NAME' in $ENV ($REGION)."
echo "All DynamoDB data, Redis state, and Lambda functions will be destroyed."
read -p "Type the stack name to confirm: " CONFIRM

if [ "$CONFIRM" = "$STACK_NAME" ]; then
  $CFN delete-stack --stack-name $STACK_NAME
  echo "Deletion started. Waiting for completion (~10–15 min)..."
  $CFN wait stack-delete-complete --stack-name $STACK_NAME
  echo "Stack '$STACK_NAME' deleted."
else
  echo "Confirmation did not match. Aborted."
fi
```

---

### _Script 8 — full-teardown (complete clean slate)_

_Removes the CloudFormation stack **and** all manually-created resources outside it._  
_Use before a re-deploy from scratch, or to decommission permanently._  
_Run **Script 6 (close-queue)** first if a sale is in progress._

> **_Note on timing:_** `cfn wait stack-delete-complete` _can take 10–20 minutes — mostly waiting for the Valkey Serverless cache and CloudFront distribution to fully decommission. This is normal._

> **_Note on Secrets Manager:_** _Secrets are soft-deleted with a 7-day recovery window by default. If you plan to re-deploy the same_ `$STACK_NAME` _within 7 days, run step 5 to force-delete them. Otherwise the re-deploy will fail with a secret name conflict._

```bash
# ── 0. Stop the inlet first (safety) ─────────────────────────────────────
#    Rule lives in $INLET_STACK_NAME, not $STACK_NAME.
INLET_RULE=$($CFN describe-stack-resource \
  --stack-name $INLET_STACK_NAME \
  --logical-resource-id PeriodicInletRule \
  --query "StackResourceDetail.PhysicalResourceId" --output text 2>/dev/null)
if [ -n "$INLET_RULE" ] && [ "$INLET_RULE" != "None" ]; then
  $EVT disable-rule --name $INLET_RULE 2>/dev/null \
    && echo "Inlet disabled: $INLET_RULE" \
    || echo "Could not disable rule (ok if already disabled)"
else
  echo "Inlet rule not found (ok)"
fi

# ── 1. Capture the LoggingBucket name before the stack is deleted ─────────
#    (DeletionPolicy: Retain — CFN intentionally leaves it behind)
LOGGING_BUCKET=$($CFN describe-stack-resource \
  --stack-name $STACK_NAME \
  --logical-resource-id LoggingBucket \
  --query "StackResourceDetail.PhysicalResourceId" --output text 2>/dev/null)
echo "LoggingBucket to remove after stack delete: $LOGGING_BUCKET"

# ── 2. Delete the CloudFormation stack ────────────────────────────────────
echo "WARNING: This will delete stack '$STACK_NAME' in $ENV ($REGION)."
echo "All DynamoDB data, Redis state, and Lambda functions will be destroyed."
read -p "Type the stack name to confirm: " CONFIRM

if [ "$CONFIRM" != "$STACK_NAME" ]; then
  echo "Confirmation did not match. Aborted."
  exit 1
fi

$CFN delete-stack --stack-name $STACK_NAME
echo "Deletion started. Waiting (~10–20 min for Valkey + CloudFront to drain)..."
$CFN wait stack-delete-complete --stack-name $STACK_NAME
echo "Stack '$STACK_NAME' deleted."

# ── 3. Empty and delete LoggingBucket (was retained by CFN) ──────────────
if [ -n "$LOGGING_BUCKET" ] && [ "$LOGGING_BUCKET" != "None" ]; then
  echo "Emptying LoggingBucket: $LOGGING_BUCKET"
  $S3C rm s3://${LOGGING_BUCKET} --recursive
  $S3C rb s3://${LOGGING_BUCKET}
  echo "LoggingBucket deleted."
fi

# ── 4. Empty and delete the artifact/build bucket ─────────────────────────
echo "Emptying artifact bucket: ${BUILD_BUCKET}-${REGION}"
$S3C rm s3://${BUILD_BUCKET}-${REGION} --recursive
$S3C rb s3://${BUILD_BUCKET}-${REGION}
echo "Artifact bucket deleted."

# ── 5. Force-delete Secrets Manager secrets (bypasses 7-day recovery window)
#    Required only if you plan to re-deploy the same $STACK_NAME within 7 days.
#    Skip if decommissioning permanently and you don't need to redeploy soon.
for SECRET_SUFFIX in redis-auth private-key public-key; do
  SECRET_ID="${STACK_NAME}/${SECRET_SUFFIX}"
  aws secretsmanager delete-secret \
    --secret-id "$SECRET_ID" \
    --force-delete-without-recovery \
    --profile $PROFILE --region $REGION 2>/dev/null \
    && echo "Force-deleted: $SECRET_ID" \
    || echo "Not found (ok): $SECRET_ID"
done

# ── 6. Remove static pages from the event site S3 bucket (if uploaded) ────
#    Only needed if you ran the upload step from Script 2.
#    Set EVENT_SITE_BUCKET to the physical bucket name of the static event page.
# EVENT_SITE_BUCKET=<your-event-site-bucket>
# $S3C rm s3://${EVENT_SITE_BUCKET}/queue/index.html
# $S3C rm s3://${EVENT_SITE_BUCKET}/buy-ticket/index.html
# echo "Static pages removed from event site bucket."

echo "============================================"
echo " Full teardown complete for '$STACK_NAME'."
echo " AWS account is back to pre-deploy state."
echo "============================================"
```

---

### _Quick Reference — Script Sequence per Scenario_

| _Scenario_                          | _Scripts to run_                               |
| ----------------------------------- | ---------------------------------------------- |
| _First deployment_                  | `0 → 1`                                        |
| _New event on existing stack_       | `0 → 2 (update EVENT_ID) → 3 → monitor with 4` |
| _Day of sale_                       | `0 → 3 → 4 (monitor) → 6 (close)`              |
| _Something stuck / testing_         | `0 → 5 (advance manually)`                     |
| _Decommission dev stack_            | `0 → 7`                                        |
| _Full clean slate / re-deploy prep_ | `0 → 6 → 8`                                    |

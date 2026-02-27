# Architecture, Cost Analysis & Tixy Usage Guide

## 1. Architecture Overview

The solution is **serverless-first**, with one always-on stateful component (Redis) and a surrounding VPC. Everything else is pay-per-use.

### Physical Architecture

```
Internet
    │
    ▼
CloudFront (CDN + caching layer)
    │
    ▼
API Gateway — Public REST API  ──►  Lambda functions (public endpoints)
API Gateway — Private REST API ──►  Lambda functions (admin endpoints, IAM auth)
    │                                        │
    │                              VPC (10.0.0.0/16)
    │                                        │
    │                         ┌──────────────┴──────────────┐
    │                   Private Subnet 1            Private Subnet 2
    │                   (10.0.16.0/20)              (10.0.32.0/20)
    │                         │                             │
    │                    Lambda (VPC) ◄──────────────► ElastiCache Redis
    │                         │                        cache.r6g.large
    │                         │                        (Primary + Replica)
    │                   NAT Gateway
    │                   (10.0.0.0/28)
    │
    ▼
SQS Queue ──► Lambda: AssignQueueNum ──► DynamoDB (3 tables)
                                         - TokenTable
                                         - QueuePositionEntryTimeTable
                                         - ServingCounterIssuedAtTable
```

### AWS Services Used

| Category | Service | Role |
|---|---|---|
| Compute | Lambda (20 functions) | All business logic |
| Queue | SQS (standard + DLQ) | Incoming request buffer |
| Cache | ElastiCache Redis | Atomic counters (queue, serving, token) |
| Database | DynamoDB (3 tables, on-demand) | Persistent state |
| API | API Gateway (2 REST APIs) | Public + private endpoints |
| CDN | CloudFront | Edge caching, HTTPS termination |
| Events | EventBridge | Decoupled event routing |
| Secrets | Secrets Manager | RSA private key, Redis password |
| Network | VPC, NAT Gateway, 5 VPC endpoints | Isolated network for Redis access |
| Observability | CloudWatch Logs + Alarms | Logging, alerting |
| Storage | S3 | CloudFront + VPC flow logs |

### Lambda Functions (20 total)

All functions: **Python 3.12, 1024 MB, 30s timeout** (except ResetState: 300s).

| Function | Trigger | VPC | Purpose |
|---|---|---|---|
| AssignQueueNum | SQS | Yes | Assigns queue positions (batch) |
| GenerateToken | API GW Public | No | Issues JWT access/refresh/id tokens |
| AuthGenerateToken | API GW Private | No | Same, for authenticated clients |
| GetQueueNum | API GW Public | No | Returns queue position for request |
| GetServingNum | API GW Public | No | Returns current serving counter |
| GetWaitingNum | API GW Public | Yes | Returns waiting count |
| GetQueuePositionExpiryTime | API GW Public | No | Returns expiry info for a position |
| GetPublicKey | API GW Public | No | Returns JWK public key |
| IncrementServingCounter | API GW Private | No | Advances serving counter |
| UpdateSession | API GW Private | No | Marks session complete/abandoned |
| GetNumActiveTokens | API GW Private | No | Returns count of active tokens |
| GetListExpiredTokens | API GW Private | No | Lists expired tokens |
| ResetState | API GW Private | No | Resets all Redis counters |
| SetQueuePositionExpired | EventBridge (1 min) | Yes | Processes expired positions |
| GenerateEvents | EventBridge | Yes | Optional: publishes queue events |
| PeriodicInlet | EventBridge (1 min) | No | Advances serving counter on schedule |
| MaxSizeInlet | SNS | No | Advances counter based on capacity |
| GenerateKeys | CloudFormation CR | No | Creates RSA key pair |
| InitializeState | CloudFormation CR | No | Seeds Redis counters |
| UpdateDistribution | CloudFormation CR | No | Updates CloudFront config |

---

## 2. Cost Analysis

### Always-On Costs (running 24/7 regardless of traffic)

| Resource | Config | Monthly Cost |
|---|---|---|
| ElastiCache Redis | `cache.r6g.large` × 2 nodes (primary + replica) | ~$252 |
| NAT Gateway | 1× NAT GW (base fee) | ~$33 |
| VPC Interface Endpoints | 4 interface endpoints × ~$7.30 | ~$29 |
| **Total always-on** | | **~$314/month** |

> ElastiCache is the dominant cost driver. It cannot be paused — only deleted and recreated.

### On-Demand Costs (scale with traffic)

These cost **$0 when idle**:

| Resource | Pricing |
|---|---|
| Lambda | $0.0000166667/GB-sec + $0.20/1M requests |
| DynamoDB | $1.25/1M writes, $0.25/1M reads, $0.25/GB storage |
| API Gateway | $3.50/1M requests |
| CloudFront | $0.085/GB + $0.0075/10K requests |
| SQS | $0.40/1M requests |
| EventBridge | $1.00/1M events |
| Secrets Manager | $0.40/secret/month |
| CloudWatch Alarms | $0.10/alarm/month |

### Traffic-Based Cost Estimates

#### Scenario A — Small Sale (10,000 users, 1-hour event)

| Service | Estimate | Monthly (1 event/month) |
|---|---|---|
| Always-on base | — | $314 |
| Lambda (10K queue + 10K tokens) | ~$0.10 | $0.10 |
| DynamoDB | ~$0.05 | $0.05 |
| API Gateway (100K requests) | ~$0.35 | $0.35 |
| CloudFront | ~$0.10 | $0.10 |
| SQS | ~$0.01 | $0.01 |
| **Total** | | **~$315/month** |

#### Scenario B — Large Sale (100,000 users, 1-hour event)

| Service | Estimate | Monthly (1 event/month) |
|---|---|---|
| Always-on base | — | $314 |
| Lambda | ~$1.00 | $1.00 |
| DynamoDB | ~$0.50 | $0.50 |
| API Gateway (1M requests) | ~$3.50 | $3.50 |
| CloudFront | ~$1.00 | $1.00 |
| SQS | ~$0.10 | $0.10 |
| **Total** | | **~$320/month** |

#### Scenario C — Multiple Events Per Month (4 events × 50K users)

| Service | Monthly |
|---|---|
| Always-on base | $314 |
| On-demand (4× Scenario B scale) | ~$20 |
| **Total** | **~$334/month** |

**Key insight:** The always-on Redis cost dominates. On-demand usage costs are minimal even at large scale.

### Cost Optimisation Options

| Option | Saving | Trade-off |
|---|---|---|
| Downsize Redis to `cache.r6g.medium` | ~$126/month | Less memory (~6 GB vs ~13 GB) |
| Downsize Redis to `cache.t4g.micro` (dev) | ~$230/month | No Multi-AZ, unsuitable for prod |
| Reserved Instance (1-year) on Redis | ~30% | Upfront commitment |
| Single Redis node (no replica) | ~$126/month | No failover |
| Replace Redis with DynamoDB counters | ~$252/month | Higher latency, may not handle burst |
| NAT Instance instead of NAT Gateway | ~$20/month | More maintenance |

**Recommended for Tixy (production):** Single `cache.r6g.medium` node with 1-year reserved = ~**$100–120/month** always-on cost, plus on-demand usage.

---

## 3. On/Off Strategy for Tixy

### The Core Problem

ElastiCache **cannot be paused or stopped** — it runs and bills 24/7. The only options are:

- **Delete and recreate** — full teardown between events (~15–20 min to redeploy)
- **Keep running** — pay ~$314/month regardless of activity
- **Resize down between events** — use `cache.t4g.micro` between events, scale up before a sale

### Recommended Approach for a Ticketing App

Since ticket sales are predictable events (not continuous traffic), the best strategy depends on how often you run sales:

---

#### Option 1: Always-On, Right-Sized (Recommended for >2 events/month)

Keep the stack permanently deployed but with an optimised instance size:

- Use `cache.r6g.medium` (1 node, no replica) between events: ~$87/month
- Scale up to `cache.r6g.large` (2 nodes) before high-traffic sales via CloudFormation parameter update

**Monthly cost:** ~$100–130/month

**Pros:**
- Instant readiness — no deployment lag before a sale
- Simple operations
- Stack is always available for testing

**Cons:**
- Fixed monthly cost even in quiet months

---

#### Option 2: Deploy-Before / Teardown-After (Best for <2 events/month)

Automate full stack deployment before each sale and teardown after:

```
T-30 min: Deploy CloudFormation stack (takes ~15–20 min)
T-0:      Sale opens, traffic flows through waiting room
T+end:    Tear down stack via CloudFormation delete
```

**Monthly cost:** Pay only for the hours the stack is running
- Example: 2-hour sale = 2× Redis hours (~$0.35) + NAT + on-demand = < $5 per event

**Pros:**
- Near-zero cost between events
- Clean state for each sale (no stale queue data)

**Cons:**
- ~15–20 min deployment time (can be automated with CI/CD)
- Risk: deployment failure before a sale
- Requires automation to be reliable

---

#### Option 3: Hybrid — Persistent Core, Scale on Demand

Keep the stack deployed on the smallest Redis instance. Before each sale:
1. Update the CloudFormation parameter `CacheNodeType` to `cache.r6g.large`
2. CloudFormation triggers a Redis cluster modification (~5–10 min)
3. After the sale, downscale back

**Between events:** `cache.t4g.small` (~$23/month) + NAT + endpoints = ~$65/month
**During events:** `cache.r6g.large` (2 nodes) = ~$314/month equivalent

---

### On/Off Automation — What to Build for Tixy

#### Pre-Sale Checklist (automated)

```bash
# 1. Deploy or update stack
aws cloudformation deploy \
  --stack-name tixy-waiting-room \
  --template-file virtual-waiting-room-on-aws.json \
  --parameter-overrides CacheNodeType=cache.r6g.large \
  --capabilities CAPABILITY_IAM

# 2. Reset queue state (clean slate for new sale)
POST /api/reset_initial_state  (private API, IAM auth)

# 3. Configure inlet strategy (how fast to let users through)
# Update PeriodicInlet or MaxSizeInlet Lambda env vars

# 4. Point tixyapp.com traffic to CloudFront URL
```

#### Post-Sale Checklist (automated)

```bash
# 1. Mark sale as ended (stop inlet strategy)
# Disable EventBridge rule for PeriodicInlet

# 2. Optionally: delete stack (Option 2) or downsize Redis (Option 3)
aws cloudformation delete-stack --stack-name tixy-waiting-room
# OR
aws cloudformation deploy ... --parameter-overrides CacheNodeType=cache.t4g.small
```

#### Integration Points for tixyapp.com

| Integration | How |
|---|---|
| Redirect high traffic to waiting room | Update DNS / CloudFront behaviour to route to waiting room CloudFront URL |
| Let users through to checkout | When JWT issued, redirect to `tixyapp.com/checkout?token=<jwt>` |
| Validate token server-side | Call Private API `POST /validate_token` or use the Lambda Authorizer |
| Control pace (inlet strategy) | Use Periodic Inlet: set `INCREMENT_BY` = tickets per minute you want to allow through |
| Monitor queue depth | Call `GET /waiting_num` and `GET /serving_num` from admin panel |
| Reset between sales | Call `POST /reset_initial_state` via Private API |

---

## 4. Architecture Diagram — Tixy Integration

```
User visits tixyapp.com/buy-tickets
    │
    ├─── Traffic normal? ──► bypass waiting room, go straight to checkout
    │
    └─── Traffic surge? ──► redirect to Waiting Room CloudFront URL
                                    │
                                    ▼
                        User enters queue (SQS → Lambda → DynamoDB)
                                    │
                        Client polls GET /queue_num every 5s
                                    │
                        Periodic Inlet ticks every minute
                        (advances serving_counter by N)
                                    │
                        queue_position <= serving_counter?
                                    │
                                    ▼
                        POST /generate_token → JWT issued
                                    │
                                    ▼
                        Redirect to tixyapp.com/checkout?token=<jwt>
                                    │
                                    ▼
                        tixyapp.com validates JWT (Lambda Authorizer or API call)
                                    │
                                    ▼
                        User completes purchase → POST /update_session (status=1)
```

---

## 5. Summary & Recommendation for Tixy

| Criteria | Assessment |
|---|---|
| Is it production-ready? | Yes — but the project is deprecated; plan for long-term maintenance |
| Suitable for ticketing? | Yes — exactly the use case it was built for |
| On/off capability | Partial — serverless components are free when idle; Redis is always-on |
| Minimum cost (idle) | ~$65–100/month (downsized Redis) |
| Cost during a sale | +$5–20 on top of base, depending on scale |
| Deployment time | ~15–20 min from scratch; ~5–10 min to resize |
| Key risk | Deprecated codebase — no security patches; Python 3.12 Lambda runtime needs monitoring |

**Bottom line:** For Tixy, **Option 1 (always-on, right-sized)** at ~$100–120/month is the most operationally safe. If you run fewer than 2 sales per month, **Option 2 (deploy/teardown)** with automated CI/CD pipeline can cut costs to nearly zero between events.

The biggest action item is addressing the deprecation — consider either forking and maintaining it internally, or evaluating the AWS Marketplace alternatives the project README points to.

---

## 6. ElastiCache Serverless — Feasibility Analysis

### Is it possible?

**Yes — with minimal code changes.** Here is why it works and what needs changing.

### Command compatibility audit

Every Redis command used in the codebase was checked against the official ElastiCache Serverless supported commands list. All are fully supported:

| Command | Used in | Serverless support |
|---|---|---|
| `GET` | 8 functions | Supported |
| `INCR` | assign_queue_num, update_session | Supported |
| `INCRBY` | increment_serving_counter, set_max_queue_position_expired | Supported |
| `GETSET` | reset_initial_state (reset counters) | Supported |
| `SET` | set_max_queue_position_expired, reset_initial_state | Supported |

No pipelines, transactions (MULTI/EXEC), Lua scripts, pub/sub, streams, or complex data types (hashes, sorted sets, etc.) are used anywhere. The data model is purely 8 simple string keys holding integer counter values. Total data stored is under 1 KB — trivially small.

### The one breaking change: authentication

This is the only real code change required. The current code authenticates with a password from Secrets Manager:

```python
redis.Redis(
    host=REDIS_HOST,
    port=REDIS_PORT,
    ssl=True,
    decode_responses=True,
    password=redis_auth   # <-- password-only auth (node-based)
)
```

ElastiCache Serverless **does not support password-only AUTH**. It uses RBAC (Role-Based Access Control) with `username` + `password`, or IAM authentication.

The fix is a one-line change per Lambda function (or a single change to a shared connection helper if you refactor first):

```python
redis.Redis(
    host=REDIS_HOST,
    port=REDIS_PORT,
    ssl=True,
    decode_responses=True,
    username='default',     # <-- RBAC: add username
    password=redis_auth
)
```

Since the same `redis.Redis()` connection pattern is repeated across 13 Lambda functions, the cleanest approach is to centralise it into a shared `get_redis_client()` utility in the shared library, then change it in one place.

### What else changes

| Area | Change required |
|---|---|
| CloudFormation | Replace `AWS::ElastiCache::ReplicationGroup` with `AWS::ElastiCache::ServerlessCache` |
| Endpoint env var | `REDIS_HOST` points to serverless endpoint (different format) |
| Auth secret | Update Secrets Manager secret format to include `username` field |
| VPC endpoints | Serverless creates its own VPC endpoint in your subnets — the 4 existing interface endpoints are unaffected |
| NAT Gateway | Still needed for Lambdas that call external APIs (Secrets Manager, etc.) |
| Security group | Update to allow traffic from Lambda subnets to the serverless cache endpoint |

### Cost comparison

The waiting room uses 8 keys averaging ~10 bytes each. Total stored data ≈ 80 bytes — far below any minimum.

**Serverless pricing (Redis OSS, us-east-1):**
- Data storage: $0.125/GB-hour, **minimum 1 GB**
- ECPUs: $0.00340 per million (1 ECPU per KB transferred per command)

**For Tixy's workload** (polling every 5 seconds, 50K concurrent users during a sale):

| Scenario | Provisioned (`cache.r6g.large` ×2) | Serverless (Redis OSS) |
|---|---|---|
| Idle month (no sales) | ~$252 | ~$91 (1 GB minimum × 730 hrs) |
| 1 sale/month (2h, 50K users) | ~$252 | ~$91 + ~$0.15 in ECPUs |
| 4 sales/month | ~$252 | ~$91 + ~$0.60 in ECPUs |
| **Monthly saving** | — | **~$161/month** |

**Bonus — switch to Valkey engine instead of Redis OSS:**

Valkey is 100% Redis-compatible (the same `redis-py` client works unchanged), but priced 33% lower on Serverless:
- Storage: $0.0837/GB-hour, **minimum 100 MB** (not 1 GB)
- ECPUs: $0.002278 per million

| Scenario | Valkey Serverless |
|---|---|
| Idle month | ~$6/month (100 MB minimum) |
| 1 sale/month | ~$6 + ~$0.10 |
| **vs provisioned Redis** | **~$246/month saving** |

### Latency impact

ElastiCache Serverless adds ~1 ms of overhead compared to provisioned (due to its internal proxy layer). For the waiting room use case — where clients poll every 5 seconds — this is completely irrelevant.

### Recommendation

**Switch to ElastiCache Serverless for Valkey.** Here is the full reasoning:

| Criterion | Verdict |
|---|---|
| Code changes required | Minimal — auth method + CloudFormation only |
| Command compatibility | 100% — all 5 commands are supported |
| Cost | $6–92/month vs $252/month provisioned |
| Idle cost | Near-zero with Valkey ($6/month min) |
| On/off behaviour | Still always-on, but base cost is negligible with Valkey |
| Automatic scaling | Yes — no pre-provisioning needed for traffic spikes |
| High availability | Built-in — no replica configuration needed |
| Latency | +~1 ms overhead — irrelevant for polling workloads |
| Risk | Low — all commands compatible, auth change is 1 line |

### Migration steps

1. **Refactor Redis connection** into a shared `get_redis_client()` helper in `source/shared/`
2. **Update the helper** to use `username='default'` + password RBAC auth
3. **Update CloudFormation** — replace `AWS::ElastiCache::ReplicationGroup` with `AWS::ElastiCache::ServerlessCache` pointing to your VPC subnets, engine `valkey`
4. **Update Secrets Manager secret** to store `{"username": "default", "password": "..."}` instead of bare password string
5. **Update env var references** in CloudFormation — `REDIS_HOST` now points to the serverless endpoint address
6. **Remove replica/node-type parameters** — serverless has no node type to configure
7. **Test** with `reset_initial_state` and a full queue assignment cycle

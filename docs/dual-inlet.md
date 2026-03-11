# Dual-Inlet Mode — Change Summary & Runbook

Deployed: 2026-03-05
Stack: `ye-poland-inlet-dev`

---

## What Changed

### Before

`virtual-waiting-room-on-aws-sample-inlet-strategy.json` used `Conditions` to
deploy **either** `PeriodicInlet` **or** `MaxSizeInlet` — never both.
The stack was running with `InletStrategy=MaxSize`, so `PeriodicInlet` was
never created and the serving counter only advanced when abandon-detection
fired via SNS. No one was let through unless someone abandoned first.

### After

**All conditions removed.** Both Lambdas and all supporting resources
(`PeriodicInletRule`, `MaxSizeInletSns`, `SnsPolicy`, permissions) are
**always deployed**, regardless of the `InletStrategy` parameter value.

| Resource | Status before | Status after |
|---|---|---|
| `PeriodicInlet` Lambda | only if `InletStrategy=Periodic` | **always** |
| `PeriodicInletRule` EventBridge rule | only if `InletStrategy=Periodic` | **always** (starts DISABLED) |
| `PeriodicInletRulePermissions` | only if `InletStrategy=Periodic` | **always** |
| `MaxSizeInlet` Lambda | only if `InletStrategy=MaxSize` | **always** |
| `MaxSizeInletSns` SNS topic | only if `InletStrategy=MaxSize` | **always** |
| `MaxSizeInletPermissions` | only if `InletStrategy=MaxSize` | **always** |
| `SnsPolicy` | only if `InletStrategy=MaxSize` | **always** |
| `InletTopicARN` CFN output | only if `InletStrategy=MaxSize` | **always** |

The `InletStrategy` parameter is kept in the template for backward
compatibility (existing scripts using `UsePreviousValue=true` still work)
but has no functional effect. Its description now says `DEPRECATED`.

`PeriodicInletRule` is created in **DISABLED** state so it does not fire
until `pre-sale.sh` explicitly enables it.

---

## How the Two Inlets Work Together

```
Every minute (when sale is open):

PeriodicInlet
  └─ POST /increment_serving_counter  (+INCREMENT_BY users admitted)
     → steady baseline drip into the venue

Concurrently, once per minute:

DetectAbandoned  (in the main waiting-room stack)
  └─ scans Redis 'heartbeats' sorted set for entries older than STALE_THRESHOLD_SECONDS
  └─ publishes {"abandoned": [...request_ids...]} to MaxSizeInletSns

MaxSizeInlet  (triggered by SNS)
  └─ POST /num_active_tokens  → how many tokens are currently live
  └─ if (MAX_SIZE - active_tokens) > 0:
       POST /increment_serving_counter  (+refill slots freed by abandons)
     → demand-driven top-up on top of the baseline
```

**Net effect:** the queue advances at a guaranteed minimum rate (`INCREMENT_BY`
per minute) and also self-heals whenever users abandon without checking out.

---

## Deployment Steps

### Prerequisites

- AWS CLI configured with the `tixy-dev` profile
- Inlet stack `ye-poland-inlet-dev` currently running (you already have it)

### Step 1 — Pull the live template

```bash
AWS_PROFILE=tixy-dev aws cloudformation get-template \
  --stack-name ye-poland-inlet-dev \
  --region eu-west-1 \
  --output json > /tmp/inlet-raw.json
```

### Step 2 — Apply the patch

```bash
python3 << 'EOF'
import json

with open('/tmp/inlet-raw.json') as f:
    outer = json.load(f)

body = outer['TemplateBody']
t = json.loads(body) if isinstance(body, str) else body

for r in t['Resources'].values():
    r.pop('Condition', None)

t['Resources']['PeriodicInletRule']['Properties']['State'] = 'DISABLED'
t['Outputs']['InletTopicARN'].pop('Condition', None)
t.pop('Conditions', None)

t['Parameters']['InletStrategy']['Description'] = (
    'DEPRECATED — both Periodic and MaxSize inlets are now always deployed. '
    'Use IncrementBy for periodic rate and MaxSize for capacity cap.'
)
t['Parameters']['InletStrategy']['AllowedValues'] = ['Periodic', 'MaxSize', 'Both']
t['Parameters']['InletStrategy']['Default'] = 'Both'

with open('/tmp/inlet-patched.json', 'w') as f:
    json.dump(t, f)

remaining = [k for k, v in t['Resources'].items() if 'Condition' in v]
print('Remaining conditions:', remaining or 'none ✓')
print('Resources:', list(t['Resources'].keys()))
EOF
```

Expected output:
```
Remaining conditions: none ✓
Resources: ['PeriodicInlet', 'InletRole', 'PeriodicInletRule', 'PeriodicInletRulePermissions',
            'MaxSizeInlet', 'MaxSizeInletPermissions', 'MaxSizeInletSns', 'SnsPolicy']
```

### Step 3 — Update the stack

```bash
AWS_PROFILE=tixy-dev aws cloudformation update-stack \
  --stack-name ye-poland-inlet-dev \
  --template-body file:///tmp/inlet-patched.json \
  --parameters \
    ParameterKey=EventId,UsePreviousValue=true \
    ParameterKey=PrivateCoreApiEndpoint,UsePreviousValue=true \
    ParameterKey=CoreApiRegion,UsePreviousValue=true \
    ParameterKey=InletStrategy,ParameterValue=Both \
    ParameterKey=IncrementBy,UsePreviousValue=true \
    ParameterKey=StartTime,UsePreviousValue=true \
    ParameterKey=EndTime,UsePreviousValue=true \
    ParameterKey=CloudWatchAlarmName,UsePreviousValue=true \
    ParameterKey=MaxSize,UsePreviousValue=true \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
  --region eu-west-1
```

### Step 4 — Wait for UPDATE_COMPLETE

```bash
AWS_PROFILE=tixy-dev aws cloudformation wait stack-update-complete \
  --stack-name ye-poland-inlet-dev \
  --region eu-west-1
```

### Step 5 — Verify both Lambdas exist

```bash
AWS_PROFILE=tixy-dev aws lambda list-functions \
  --region eu-west-1 \
  --query "Functions[?starts_with(FunctionName,'ye-poland-inlet')].FunctionName" \
  --output table
```

Expected: both `ye-poland-inlet-dev-PeriodicInlet-*` and
`ye-poland-inlet-dev-MaxSizeInlet-*` appear.

---

## How to Test

### A — Manual trigger of PeriodicInlet

```bash
# Find the physical function name
PERIODIC_FN=$(AWS_PROFILE=tixy-dev aws cloudformation describe-stack-resource \
  --stack-name ye-poland-inlet-dev \
  --logical-resource-id PeriodicInlet \
  --region eu-west-1 \
  --query StackResourceDetail.PhysicalResourceId \
  --output text)

# Invoke it synchronously
AWS_PROFILE=tixy-dev aws lambda invoke \
  --function-name "$PERIODIC_FN" \
  --region eu-west-1 \
  --payload '{}' \
  /tmp/periodic-out.json && cat /tmp/periodic-out.json
```

Then check that the serving counter incremented:

```bash
curl -s -H "x-api-key: <YOUR_API_KEY>" \
  "https://d3j12ztg52wyqw.cloudfront.net/api/serving_num?event_id=ye-poland-2026-04" | jq .
```

### B — Manual trigger of MaxSizeInlet via SNS

```bash
# Publish a fake abandon event to the SNS topic
AWS_PROFILE=tixy-dev aws sns publish \
  --topic-arn "arn:aws:sns:eu-west-1:081111355078:ye-poland-inlet-dev-MaxSizeInletSns-YGNNzOP8gxjH" \
  --message '{"abandoned": ["test-rid-001", "test-rid-002"]}' \
  --region eu-west-1
```

Watch the `MaxSizeInlet` CloudWatch log group
(`/aws/lambda/ye-poland-inlet-dev-MaxSizeInlet-*`) for the invocation log.

### C — End-to-end heartbeat + abandon flow

1. Open the queue page: `https://des8t03j9cqvz.cloudfront.net/queue/index.html?event_id=ye-poland-2026-04`
2. Open browser DevTools → Network tab
3. Verify `POST .../heartbeat` fires every 30 seconds with your `request_id`
4. **Kill the tab** (or wait 90 s without interacting)
5. In CloudWatch, find the `DetectAbandoned` log group and confirm a log line like:
   ```
   detect_abandoned: published 1 abandoned request_ids to SNS
   ```
6. Check the `MaxSizeInlet` log group — it should fire with an `increment_serving_counter` call
7. Check the `serving_num` endpoint again — counter should have increased

### D — Enable PeriodicInletRule (simulate sale open)

```bash
RULE_NAME=$(AWS_PROFILE=tixy-dev aws cloudformation describe-stack-resource \
  --stack-name ye-poland-inlet-dev \
  --logical-resource-id PeriodicInletRule \
  --region eu-west-1 \
  --query StackResourceDetail.PhysicalResourceId \
  --output text)

AWS_PROFILE=tixy-dev aws events enable-rule \
  --name "$RULE_NAME" \
  --region eu-west-1
```

Watch `/aws/lambda/ye-poland-inlet-dev-PeriodicInlet-*` — a new invocation
log should appear within 60 seconds. Confirm the serving counter advances
by `INCREMENT_BY` (500) each minute.

Disable again after testing:

```bash
AWS_PROFILE=tixy-dev aws events disable-rule \
  --name "$RULE_NAME" \
  --region eu-west-1
```

---

## Key Configuration Values

| Setting | Location | Current value |
|---|---|---|
| `INCREMENT_BY` | inlet stack parameter | 500 users/minute |
| `MaxSize` | inlet stack parameter | 1000 concurrent tokens |
| Heartbeat interval | `queue/index.html` JS | 30 s |
| `StaleThresholdSeconds` | main stack parameter | 90 s (3 missed pings) |
| `DetectAbandoned` schedule | main stack EventBridge rule | every 1 minute |

---

## Rollback

To disable `PeriodicInlet` without deleting it, disable the EventBridge rule:

```bash
AWS_PROFILE=tixy-dev aws events disable-rule \
  --name "$RULE_NAME" \
  --region eu-west-1
```

This leaves `MaxSizeInlet` active (demand-driven) while the baseline drip
is paused — useful for rate-limiting during unexpected load spikes.

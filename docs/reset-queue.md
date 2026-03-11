## Option A — Just reset counters (same event ID, for testing)

Call the private API's reset endpoint directly:

```bash
source .env.dev

awscurl \
  --service execute-api \
  --region "$REGION" \
  --profile "$PROFILE" \
  -X POST "${PRIVATE_API_URL}/reset_initial_state" \
  -H "Content-Type: application/json" \
  -d "{\"event_id\": \"${EVENT_ID}\"}"
```

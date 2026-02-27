# Sample Static Pages

Zero-dependency static HTML pages that replicate the Vue sample app.  
No build step — open in a browser or drop straight into S3.

## Files

```
queue/
  index.html       ← Waiting room page (S3 + CloudFront)
buy-ticket/
  index.html       ← Token-gated buy ticket page (Amplify example)
```

## Setup

### 1. Deploy the waiting room stack

Follow the main install guide to deploy `virtual-waiting-room-on-aws.json`.  
Note down:
- **Core API URL** — the API Gateway base URL (e.g. `https://xxxx.execute-api.eu-west-1.amazonaws.com/api`)
- **Event ID** — the event ID you passed to the stack

### 2. Configure `queue/index.html`

Edit the `CONFIG` block at the top of the file:

```js
const CONFIG = {
  PUBLIC_API_URL:  'https://xxxx.execute-api.eu-west-1.amazonaws.com/api',
  EVENT_ID:        'my-event-id',
  BUY_TICKET_URL:  'https://main.xxxx.amplifyapp.com/buy-ticket',
};
```

### 3. Configure `buy-ticket/index.html`

Edit the `CONFIG` block:

```js
const CONFIG = {
  QUEUE_URL:  'https://your-cloudfront-url/queue/index.html',
  EVENT_ID:   'my-event-id',   // must match the queue page
};
```

### 4. Upload to S3 and serve via CloudFront

```
your-bucket/
  queue/index.html
  buy-ticket/index.html    ← optional; normally lives in your Amplify app
```

The `queue/` path should be a CloudFront behaviour pointing at the S3 origin.

---

## Full Dev Flow

```
1. User visits static event page (CloudFront)
   └── CloudFront Function: no token? → redirect to /queue/index.html

2. queue/index.html
   ├── POST  /assign_queue_num   → gets requestId
   ├── GET   /queue_num          → gets myPosition
   ├── polls /serving_num        → tracks progress (every 3 s)
   ├── polls /waiting_num        → shows queue size (every 3 s)
   └── POST  /generate_token     → gets JWT, then redirects to:
       [BUY_TICKET_URL]?wvroom_token=<jwt>

3. buy-ticket/index.html (or your Amplify /buy-ticket route)
   ├── Reads ?wvroom_token from URL (or sessionStorage / cookie)
   ├── Decodes JWT — checks expiry + event_id client-side (UX only)
   └── Calls purchase API with token in Authorization header
       (Phase 1: mock  |  Phase 2: real AppSync mutation)
```

## Token handoff — dev vs prod

| Environment | How token is passed | Why |
|---|---|---|
| Dev | URL query param `?wvroom_token=` | Different origins — no cookie sharing |
| Prod | Cookie `.ye-poland.com` + URL param | `buy.ye-poland.com` is a subdomain — cookie works |

## Phase 2 — AppSync Lambda Authorizer

`buy-ticket/index.html` contains a commented-out block showing the Amplify  
GraphQL call using `authMode: 'lambda'`. Once you've deployed the AppSync  
Lambda Authorizer, replace the mock in `completePurchase()` with that call.

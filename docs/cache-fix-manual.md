## Step 1 — Create a Cache Policy

1. Go to **CloudFront → Policies → Cache tab**.
2. Click **Create cache policy**.
3. Fill in the following fields:
   - **Name:** `WaitingRoomPolling`
   - **Minimum TTL:** `3`
   - **Default TTL:** `3`
   - **Maximum TTL:** `3`

4. Under **Cache key settings → Query strings**, select **Include specified query strings** and add `event_id`.
5. **Headers:** None
6. **Cookies:** None
7. Click **Create**.

---

## Step 2 — Add Cache Behaviors to the Public API Distribution

1. Go to **CloudFront → Distributions** and open the one used for the **Public API** (the one whose domain is in your `PUBLIC_API_URL`).
2. Click the **Behaviors** tab → **Create behavior**.

### First behavior — serving counter

- **Path pattern:** `/serving_num*`
- **Origin:** Existing API Gateway origin
- **Viewer protocol policy:** Redirect HTTP to HTTPS
- **Allowed HTTP methods:** GET, HEAD
- **Cache policy:** `WaitingRoomPolling` (the one you just created)
- **Origin request policy:** `AllViewerExceptHostHeader` (or whichever is already used by the default behavior)

Click **Save changes**.

### Second behavior — waiting count

Repeat the same settings, but set:

- **Path pattern:** `/waiting_num*`

Click **Save changes**.

---

## Step 3 — Verify

1. Wait about **2 minutes** for the distribution to deploy (status will change from “Deploying” back to “Enabled”).
2. Open **browser DevTools** on the queue page → **Network tab**.
3. Look for requests to `/serving_num` and `/waiting_num`.

After the first request, you sh

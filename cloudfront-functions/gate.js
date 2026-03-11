// Phase 1.5 — expiry + structure check (no RS256 signature verification).
//
// CloudFront Functions (cloudfront-js-2.0) exposes only crypto.createHash and
// crypto.createHmac — RSA primitives are not available. Full RS256 signature
// verification requires Lambda@Edge; see gate-lambda-edge.js for the Phase 2
// implementation.
//
// This function defends against:
//   - Missing token        → redirect to /queue
//   - Malformed JWT        → redirect to /queue
//   - Expired token (exp)  → redirect to /queue
//
// Gated paths: anything under /buy-ticket
// Allowed always: /, /queue/*, and everything else (static event content)

function handler(event) {
  var request = event.request;
  var uri = request.uri;

  // Only gate the buy-ticket path; let the queue page and event page through.
  if (!uri.startsWith('/buy-ticket')) {
    return request;
  }

  var cookies = request.cookies;
  var token = cookies['wvroom_token'] ? cookies['wvroom_token'].value : null;

  // Also accept token passed as URL query param (dev cross-domain flow).
  if (!token) {
    var qs = request.querystring;
    if (qs && qs['wvroom_token']) {
      token = qs['wvroom_token'].value;
    }
  }

  if (!token) {
    return redirect('/queue/index.html');
  }

  // Validate JWT structure: must have exactly 3 dot-separated segments.
  var parts = token.split('.');
  if (parts.length !== 3) {
    return redirect('/queue/index.html');
  }

  // Decode payload and check expiry — cheap, no crypto required.
  try {
    var payload = JSON.parse(b64urlDecode(parts[1]));
    var now = Math.floor(Date.now() / 1000);
    if (!payload.exp || payload.exp <= now) {
      return redirect('/queue/index.html');
    }
  } catch (e) {
    return redirect('/queue/index.html');
  }

  // Token is structurally valid and not expired.
  // NOTE: signature is NOT verified here — deploy gate-lambda-edge.js
  // (Lambda@Edge) for full RS256 verification (Phase 2).
  return request;
}

function redirect(path) {
  return {
    statusCode: 302,
    statusDescription: 'Found',
    headers: { location: { value: path } }
  };
}

function b64urlDecode(str) {
  // Convert base64url to base64, then decode to a UTF-8 string.
  var base64 = str.replace(/-/g, '+').replace(/_/g, '/');
  var pad = (4 - base64.length % 4) % 4;
  for (var i = 0; i < pad; i++) { base64 += '='; }
  return Buffer.from(base64, 'base64').toString('utf-8');
}

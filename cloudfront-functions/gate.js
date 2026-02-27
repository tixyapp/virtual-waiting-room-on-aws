// Phase 1 — presence check only (no signature verification).
// Phase 2: embed RS256 public key and use crypto.subtle for full verification.
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

  // Also accept token passed as URL query param (dev cross-domain flow)
  if (!token) {
    var qs = request.querystring;
    if (qs && qs['wvroom_token']) {
      token = qs['wvroom_token'].value;
    }
  }

  if (!token) {
    return {
      statusCode: 302,
      headers: { location: { value: '/queue/index.html' } }
    };
  }

  return request;
}

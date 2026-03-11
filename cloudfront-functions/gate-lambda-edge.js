/**
 * gate-lambda-edge.js — Phase 2: RS256 + expiry verification at the edge.
 *
 * Deploy as a Lambda@Edge viewer-request function (Node.js 20.x, us-east-1).
 * Lambda@Edge provides the full Node.js crypto module, which includes
 * crypto.createVerify() for RSA-SHA256 — unavailable in CloudFront Functions.
 *
 * JWKS_N and JWKS_E are injected by deploy-gate.sh at deploy time from the
 * current /public_key endpoint.  Never edit these values manually.
 *
 * Gated paths: anything under /buy-ticket
 * Allowed always: /, /queue/*, and everything else (static event content)
 */

'use strict';

const crypto = require('crypto');

// RSA public key components (base64url-encoded) — injected by deploy-gate.sh.
const JWKS_N = '__REPLACE_WITH_N__';   // RSA modulus
const JWKS_E = '__REPLACE_WITH_E__';   // RSA public exponent (typically 'AQAB')
const COOKIE_NAME = 'wvroom_token';

// Build a PEM public key string from JWK n/e at module load time so it is
// only computed once per Lambda@Edge cold start.
const PUBLIC_KEY_PEM = buildPemFromJwk(JWKS_N, JWKS_E);

exports.handler = async (event) => {
  const request = event.Records[0].cf.request;
  const uri = request.uri;

  // Pass through all non-buy-ticket paths.
  if (!uri.startsWith('/buy-ticket')) {
    return request;
  }

  const token = extractToken(request);
  if (!token) {
    return redirect('/queue/index.html');
  }

  const parts = token.split('.');
  if (parts.length !== 3) {
    return redirect('/queue/index.html');
  }

  try {
    // 1. Decode payload and check expiry first — cheap path.
    const payload = JSON.parse(b64urlToUtf8(parts[1]));
    const now = Math.floor(Date.now() / 1000);
    if (!payload.exp || payload.exp <= now) {
      return redirect('/queue/index.html');
    }

    // 2. Verify RS256 signature.
    const signingInput = parts[0] + '.' + parts[1];
    const signatureBytes = Buffer.from(parts[2], 'base64url');
    const valid = crypto
      .createVerify('RSA-SHA256')
      .update(signingInput)
      .verify(PUBLIC_KEY_PEM, signatureBytes);

    if (!valid) {
      return redirect('/queue/index.html');
    }
  } catch (e) {
    // Any error (malformed base64, invalid JSON, crypto failure) → reject.
    return redirect('/queue/index.html');
  }

  return request;
};

// ── Helpers ──────────────────────────────────────────────────────────────────

function extractToken(request) {
  // Check cookie first.
  const cookieHeader = (request.headers['cookie'] || []).map(h => h.value).join('; ');
  const match = cookieHeader.match(new RegExp('(?:^|;\\s*)' + COOKIE_NAME + '=([^;]+)'));
  if (match) return decodeURIComponent(match[1]);

  // Fallback: URL query param (dev cross-domain flow).
  const qs = request.querystring || '';
  const qsMatch = qs.match(/(?:^|&)wvroom_token=([^&]+)/);
  if (qsMatch) return decodeURIComponent(qsMatch[1]);

  return null;
}

function redirect(location) {
  return {
    status: '302',
    statusDescription: 'Found',
    headers: { location: [{ key: 'Location', value: location }] }
  };
}

function b64urlToUtf8(str) {
  return Buffer.from(str, 'base64url').toString('utf-8');
}

/**
 * Build a PKCS#8 PEM public key string from JWK n/e components.
 * Node.js crypto.createPublicKey() accepts JWK directly from Node 15+;
 * Lambda@Edge uses Node 20.x so this is safe to use.
 */
function buildPemFromJwk(n, e) {
  const publicKey = crypto.createPublicKey({
    key: { kty: 'RSA', n, e },
    format: 'jwk'
  });
  return publicKey.export({ type: 'pkcs1', format: 'pem' });
}

// Cloudflare Worker that starts the "Status pages to Slack" workflow every 5 minutes.
// GitHub's own schedule is best-effort and often runs hours apart; a workflow_dispatch call
// (the same as the "Run workflow" button) starts right away.
//
// It signs in to GitHub as a GitHub App owned by the hosting-support org, so there's no
// personal token to renew: on every run it signs a short-lived JWT with the app's private key,
// swaps it for a 1-hour installation token, and uses that to start the workflow.
//
// Setup (Cloudflare dashboard -> Workers & Pages -> this Worker):
//   Settings -> Variables and Secrets:
//     GITHUB_APP_ID           the app's "App ID" (a number, on the app's settings page)
//     GITHUB_APP_PRIVATE_KEY  the whole .pem file the app's "Generate a private key" button
//                             downloads, including the BEGIN/END lines
//   Settings -> Trigger Events: cron trigger */5 * * * *
// The app needs Repository permission "Actions: Read and write" and must be installed on
// this repository. Without the two app secrets it falls back to a GITHUB_TOKEN secret (a
// fine-grained personal token with the same permission), which is how it worked before.

const REPO = 'hosting-support/status-pages-slack';
const WORKFLOW = 'status-to-slack.yml';
const BRANCH = 'main';
const API = 'https://api.github.com';
const HEADERS = {
  'Accept': 'application/vnd.github+json',
  'X-GitHub-Api-Version': '2022-11-28',
  'User-Agent': 'status-pages-trigger',
};

export default {
  async scheduled(event, env, ctx) {
    const token = await getToken(env);
    const res = await fetch(`${API}/repos/${REPO}/actions/workflows/${WORKFLOW}/dispatches`, {
      method: 'POST',
      headers: { ...HEADERS, 'Authorization': `Bearer ${token}` },
      body: JSON.stringify({ ref: BRANCH }),
    });
    // GitHub answers 204 when the run was started; anything else shows as an error in the
    // Worker's logs (e.g. 401 = bad credentials, 403/404 = the app or token has no access)
    if (res.status !== 204) {
      throw new Error(`Starting the workflow: GitHub returned ${res.status}: ${await res.text()}`);
    }
  },

  // Visiting the Worker's URL doesn't start anything; it just says what this is.
  async fetch() {
    return new Response(`Starts the ${WORKFLOW} workflow in ${REPO} every 5 minutes.\n`, {
      headers: { 'Content-Type': 'text/plain' },
    });
  },
};

// ---- GitHub sign-in ----

async function getToken(env) {
  if (!env.GITHUB_APP_ID || !env.GITHUB_APP_PRIVATE_KEY) {
    if (env.GITHUB_TOKEN) return env.GITHUB_TOKEN;   // the old personal-token setup
    throw new Error('No GitHub credentials: set GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY');
  }
  const jwt = await makeAppJwt(String(env.GITHUB_APP_ID).trim(), env.GITHUB_APP_PRIVATE_KEY);
  const asApp = { ...HEADERS, 'Authorization': `Bearer ${jwt}` };

  // the app's installation on this repository (so its id doesn't need to be a secret too)
  const inst = await fetch(`${API}/repos/${REPO}/installation`, { headers: asApp });
  if (!inst.ok) {
    throw new Error(`Finding the app's installation: GitHub returned ${inst.status}: ${await inst.text()}` +
      (inst.status === 404 ? ' (is the app installed on this repository?)' : ''));
  }
  const { id } = await inst.json();

  // a token for that installation, limited to this repository; it lasts an hour
  const tok = await fetch(`${API}/app/installations/${id}/access_tokens`, {
    method: 'POST',
    headers: asApp,
    body: JSON.stringify({ repositories: [REPO.split('/')[1]] }),
  });
  if (tok.status !== 201) {
    throw new Error(`Getting an installation token: GitHub returned ${tok.status}: ${await tok.text()}`);
  }
  return (await tok.json()).token;
}

// A JWT signed with the app's private key (RS256), valid for 9 minutes. GitHub allows at most
// 10, and the issue time is set a minute back in case the clocks differ slightly.
async function makeAppJwt(appId, pem) {
  const now = Math.floor(Date.now() / 1000);
  const enc = (obj) => b64url(new TextEncoder().encode(JSON.stringify(obj)));
  const unsigned = `${enc({ alg: 'RS256', typ: 'JWT' })}.${enc({ iat: now - 60, exp: now + 540, iss: appId })}`;
  const key = await crypto.subtle.importKey('pkcs8', pemToPkcs8(pem),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned));
  return `${unsigned}.${b64url(new Uint8Array(sig))}`;
}

// GitHub hands out keys as "BEGIN RSA PRIVATE KEY" (PKCS#1), but the Web Crypto API only reads
// PKCS#8 ("BEGIN PRIVATE KEY"), so a PKCS#1 key is wrapped in the PKCS#8 structure here.
function pemToPkcs8(pem) {
  const isPkcs1 = /BEGIN RSA PRIVATE KEY/.test(pem);
  const b64 = pem.replace(/-----(BEGIN|END)[^-]*-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  if (!isPkcs1) return der.buffer;
  // PKCS#8 = SEQUENCE { INTEGER 0, SEQUENCE { OID rsaEncryption, NULL }, OCTET STRING <pkcs1> }
  const rsaAlgorithm = [0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00];
  const body = [0x02, 0x01, 0x00, ...rsaAlgorithm, 0x04, ...derLength(der.length), ...der];
  return new Uint8Array([0x30, ...derLength(body.length), ...body]).buffer;
}

function derLength(n) {
  if (n < 0x80) return [n];
  const bytes = [];
  for (; n > 0; n >>= 8) bytes.unshift(n & 0xff);
  return [0x80 | bytes.length, ...bytes];
}

function b64url(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

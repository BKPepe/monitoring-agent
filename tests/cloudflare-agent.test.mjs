// Unit tests of the Cloudflare Worker agent (cloudflare-agent.js), run with
// `node --test tests/*.test.mjs` before every Worker deploy.
//
// The Worker has no seam of its own, so the tests drive its two real entry
// points (the cron `scheduled` handler and `/run`) against a stubbed global
// fetch and read the `location` it posts to node_api.php. That string ends up
// unchanged in monitor_logs.checked_from and on the public status page, so a
// wrong country here is a wrong flag in front of every visitor.
import { test, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import worker from '../cloudflare-agent.js';

const API_URL = 'https://api.example/status/node_api.php';
const env = { API_URL, API_KEY: 'test-key' };
const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

// A trace the way https://cloudflare.com/cdn-cgi/trace prints it. `loc` is the
// country of the client IP - inside a Worker that is the Worker's own egress
// IP, which Cloudflare geolocates as US wherever the colo is.
const trace = (colo, loc = 'US') =>
  ['fl=1f1', 'h=cloudflare.com', 'ip=192.0.2.10', 'ts=1790000000.123',
    'visit_scheme=https', 'uag=Mozilla/5.0', `colo=${colo}`, 'sliver=none',
    'http=http/1.1', `loc=${loc}`, 'tls=TLSv1.3', 'sni=plaintext', 'warp=off',
    'gateway=off', 'rbi=off', 'kex=X25519'].join('\n') + '\n';

// Stubs every request the Worker makes and returns the location it posted.
// `traceReply` is a trace body, an Error to throw, or a Response.
function stubFetch(traceReply) {
  const posted = [];
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    if (url === 'https://cloudflare.com/cdn-cgi/trace') {
      if (traceReply instanceof Error) throw traceReply;
      return traceReply instanceof Response ? traceReply : new Response(traceReply);
    }
    if (url.startsWith(`${API_URL}?action=get_monitors`)) {
      return Response.json({ monitors: [{ id: 7, type: 'web', target: 'https://site.example/' }] });
    }
    if (url.startsWith(`${API_URL}?action=post_results`)) {
      posted.push(JSON.parse(init.body).location);
      return Response.json({ status: 'ok' });
    }
    if (url === 'https://site.example/') return new Response('ok');
    throw new Error(`unexpected fetch ${url}`);
  };
  return posted;
}

async function cronLocation(traceReply) {
  const posted = stubFetch(traceReply);
  const pending = [];
  await worker.scheduled({ cron: '*/5 * * * *' }, env, { waitUntil: (p) => pending.push(p) });
  await Promise.all(pending);
  assert.equal(posted.length, 1, 'výsledky odeslány právě jednou');
  return posted[0];
}

// Every colo the Worker has reported from so far, each with the country the
// colo is in. All of them were posted as ", US" before.
const SEEN = [
  ['SIN', '🇸🇬 Singapore, SG'],
  ['WAW', '🇵🇱 Warsaw, PL'],
  ['AMS', '🇳🇱 Amsterdam, NL'],
  ['BOM', '🇮🇳 Mumbai, IN'],
  ['KIX', '🇯🇵 Osaka, JP'],
  ['FRA', '🇩🇪 Frankfurt, DE'],
  ['SCL', '🇨🇱 Santiago, CL'],
  ['SLC', '🇺🇸 Salt Lake City, US'],
  ['IAD', '🇺🇸 Washington DC, US'],
  ['ORD', '🇺🇸 Chicago, US'],
  ['SEA', '🇺🇸 Seattle, US'],
];

for (const [colo, label] of SEEN) {
  test(`cron v ${colo}: země podle colo, ne podle výstupní IP Workeru (loc=US)`, async () => {
    assert.equal(await cronLocation(trace(colo, 'US')), `${label} (AS13335 Cloudflare)`);
  });
}

test('cron v Berlíně: Cloudflare hlásí colo TXL, i to je Berlín, DE', async () => {
  assert.equal(await cronLocation(trace('TXL')), '🇩🇪 Berlin, DE (AS13335 Cloudflare)');
});

test('neznámé colo: kód místo města, neutrální vlajka, žádná vymyšlená země', async () => {
  assert.equal(await cronLocation(trace('ZZX', 'US')), '🌐 ZZX (AS13335 Cloudflare)');
});

test('trace bez colo (chybová stránka): poctivé „Cloudflare Edge“, žádné prázdné místo', async () => {
  const reply = new Response('<html>503 Service Unavailable</html>', { status: 503 });
  assert.equal(await cronLocation(reply), '🌐 Cloudflare Edge (AS13335 Cloudflare)');
});

test('trace nedostupný: „Cloudflare Edge“ s neutrální vlajkou', async () => {
  assert.equal(await cronLocation(new TypeError('network down')), '🌐 Cloudflare Edge (AS13335 Cloudflare)');
});

test('ruční /run: poloha colo, kde Worker běží, ne toho, kdo /run zavolal', async () => {
  const posted = stubFetch(trace('FRA', 'US'));
  // request.cf describes the caller: here someone in Prague on their own ISP.
  const request = {
    url: 'https://worker.example/run',
    cf: { country: 'CZ', city: 'Prague', asn: 64500, asOrganization: 'Example Access Network' },
  };
  const resp = await worker.fetch(request, env, { waitUntil() {} });
  const body = await resp.json();
  assert.deepEqual(posted, ['🇩🇪 Frankfurt, DE (AS13335 Cloudflare)']);
  assert.equal(body.location, posted[0]);
});

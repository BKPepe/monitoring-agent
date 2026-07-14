/**
 * HTTP Monitoring Agent - Cloudflare Worker
 *
 * 1. Fetches monitor list from node_api.php?action=get_monitors
 * 2. Performs HTTP availability checks
 * 3. Posts results back to node_api.php?action=post_results
 *
 * Supports only HTTP/HTTPS monitors (type=web).
 * TCP ports, game servers etc. require a VPS-based agent.
 *
 * Deploy: wrangler deploy (from this directory)
 */

const CHECK_TIMEOUT_MS = 8000;
const SUPPORTED_TYPES = ['web'];

/**
 * Build a human-readable location string from Cloudflare's request metadata.
 * Uses ASN, city, country from the CF object on incoming requests.
 * Falls back to 'Cloudflare Edge' for scheduled (cron) invocations.
 */
function buildLocation(request) {
  if (!request || !request.cf) return '🌐 Cloudflare Edge';
  const cf = request.cf;
  const flag = countryFlag(cf.country);
  const city = cf.city || '';
  const country = cf.country || '';
  const asn = cf.asn ? `AS${cf.asn}` : '';
  const org = cf.asOrganization ? cf.asOrganization.split(' ').slice(0, 3).join(' ') : '';
  const asnStr = asn && org ? `${asn} ${org}` : asn || org;
  const geo = [city, country].filter(Boolean).join(', ');
  return `${flag} ${geo}${asnStr ? ` (${asnStr})` : ''}`.trim() || '🌐 Cloudflare Edge';
}

function countryFlag(code) {
  if (!code || code.length !== 2) return '🌐';
  return String.fromCodePoint(...[...code.toUpperCase()].map(c => 0x1F1E6 + c.charCodeAt(0) - 65));
}

export default {
  // HTTP handler – manual trigger via /run endpoint
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === '/run') {
      const location = buildLocation(request);
      const result = await runMonitoring(env, location);
      return new Response(JSON.stringify(result, null, 2), {
        headers: { 'Content-Type': 'application/json' }
      });
    }
    return new Response(JSON.stringify({
      status: 'ok',
      message: 'Monitoring Worker is running. Use /run to trigger manually.'
    }), { headers: { 'Content-Type': 'application/json' } });
  },

  // Scheduled cron handler
  async scheduled(event, env, ctx) {
    // No request object available on cron – location will be generic
    ctx.waitUntil(runMonitoring(env, '🌐 Cloudflare Edge'));
  }
};

async function runMonitoring(env, location) {
  const apiUrl = env.API_URL;
  const apiKey = env.API_KEY;

  if (!apiUrl || !apiKey) {
    return { error: 'Missing API_URL or API_KEY environment secrets.' };
  }

  // Fetch monitor list
  let monitors = [];
  try {
    const resp = await fetch(`${apiUrl}?action=get_monitors&key=${encodeURIComponent(apiKey)}`, {
      signal: AbortSignal.timeout(10000)
    });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const data = await resp.json();
    monitors = data.monitors || [];
  } catch (e) {
    return { error: `Failed to fetch monitors: ${e.message}` };
  }

  const supported = monitors.filter(m => SUPPORTED_TYPES.includes(m.type));

  if (supported.length === 0) {
    return { status: 'ok', message: 'No HTTP monitors to check.', total: monitors.length };
  }

  // Run checks concurrently
  const results = await Promise.all(supported.map(checkMonitor));

  // Post results
  try {
    const resp = await fetch(`${apiUrl}?action=post_results&key=${encodeURIComponent(apiKey)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ location, results }),
      signal: AbortSignal.timeout(15000)
    });
    const data = await resp.json();
    return {
      status: 'ok',
      location,
      checked: results.length,
      skipped: monitors.length - results.length,
      server_response: data
    };
  } catch (e) {
    return { error: `Failed to post results: ${e.message}`, results };
  }
}

async function checkMonitor(monitor) {
  const startMs = Date.now();
  let url = monitor.target;
  if (!url.startsWith('http://') && !url.startsWith('https://')) url = 'https://' + url;

  try {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), CHECK_TIMEOUT_MS);
    const resp = await fetch(url, {
      redirect: 'follow',
      signal: controller.signal,
      headers: { 'User-Agent': 'MonitorAgent/1.0 (Cloudflare-Worker)' }
    });
    clearTimeout(timer);
    const rt = Date.now() - startMs;
    if (resp.status >= 200 && resp.status < 400) {
      return { id: monitor.id, status: 'up', response_time: rt, error: null };
    }
    return { id: monitor.id, status: 'down', response_time: rt, error: `HTTP ${resp.status}` };
  } catch (e) {
    return {
      id: monitor.id,
      status: 'down',
      response_time: Date.now() - startMs,
      error: e.name === 'AbortError' ? `Timeout after ${CHECK_TIMEOUT_MS}ms` : e.message
    };
  }
}

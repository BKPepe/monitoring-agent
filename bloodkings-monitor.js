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

// IATA data center code → city name mapping (Cloudflare major PoPs)
const COLO_CITY = {
  AMS:'Amsterdam',ARN:'Stockholm',ATL:'Atlanta',BCN:'Barcelona',BEG:'Belgrade',
  BER:'Berlin',BKK:'Bangkok',BOM:'Mumbai',BRU:'Brussels',BUH:'Bucharest',
  CDG:'Paris',CWB:'Curitiba',DEL:'New Delhi',DFW:'Dallas',DUB:'Dublin',
  DUS:'Düsseldorf',EWR:'Newark',EZE:'Buenos Aires',FCO:'Rome',FRA:'Frankfurt',
  GIG:'Rio de Janeiro',GRU:'São Paulo',HAM:'Hamburg',HKG:'Hong Kong',
  IAD:'Washington DC',IAH:'Houston',ICN:'Seoul',IST:'Istanbul',JNB:'Johannesburg',
  KHI:'Karachi',KIX:'Osaka',LAX:'Los Angeles',LHR:'London',LIM:'Lima',
  LIS:'Lisbon',MAA:'Chennai',MAD:'Madrid',MAN:'Manchester',MEL:'Melbourne',
  MEX:'Mexico City',MIA:'Miami',MNL:'Manila',MRS:'Marseille',MUC:'Munich',
  NRT:'Tokyo',ORD:'Chicago',OSL:'Oslo',OTP:'Bucharest',PHX:'Phoenix',
  PNQ:'Pune',PRG:'Prague',QRO:'Queretaro',RUH:'Riyadh',SCL:'Santiago',
  SEA:'Seattle',SFO:'San Francisco',SIN:'Singapore',SJC:'San Jose',
  SOF:'Sofia',SYD:'Sydney',TLV:'Tel Aviv',TPE:'Taipei',VIE:'Vienna',
  WAW:'Warsaw',YUL:'Montreal',YVR:'Vancouver',YYZ:'Toronto',ZRH:'Zürich',
};

function countryFlag(code) {
  if (!code || code.length !== 2) return '🌐';
  return String.fromCodePoint(...[...code.toUpperCase()].map(c => 0x1F1E6 + c.charCodeAt(0) - 65));
}

/**
 * Detect location from Cloudflare's own trace endpoint.
 * Returns e.g. "🇩🇪 Frankfurt, DE (AS13335 Cloudflare, Inc)"
 */
async function detectLocation() {
  try {
    // Cloudflare trace gives us the PoP (colo) and country of THIS worker invocation
    const traceResp = await fetch('https://cloudflare.com/cdn-cgi/trace', {
      signal: AbortSignal.timeout(4000)
    });
    const traceText = await traceResp.text();
    const kv = Object.fromEntries(
      traceText.trim().split('\n').map(l => l.split('='))
    );
    const colo    = kv['colo'] || '';
    const country = kv['loc']  || '';
    const city    = COLO_CITY[colo] || colo;
    const flag    = countryFlag(country);

    // Also try ipinfo for ASN (best-effort)
    let asnStr = 'Cloudflare';
    try {
      const ipResp = await fetch('https://ipinfo.io/json', {
        headers: { 'User-Agent': 'MonitorAgent/1.0' },
        signal: AbortSignal.timeout(3000)
      });
      const ipData = await ipResp.json();
      const org = ipData.org || '';   // e.g. "AS13335 Cloudflare, Inc"
      if (org) asnStr = org.replace(/^AS\d+\s*/, '').split(',')[0].trim() || asnStr;
      const asn = org.match(/^AS(\d+)/)?.[1];
      if (asn) asnStr = `AS${asn} ${asnStr}`;
    } catch (_) {}

    const geo = [city, country].filter(Boolean).join(', ');
    return `${flag} ${geo} (${asnStr})`.trim();
  } catch (e) {
    return '🌐 Cloudflare Edge';
  }
}

/**
 * Build location from incoming request's cf object (for /run HTTP handler).
 */
function locationFromRequest(request) {
  if (!request?.cf) return null;
  const { asn, asOrganization, country, city } = request.cf;
  const flag    = countryFlag(country);
  const geo     = [city, country].filter(Boolean).join(', ');
  const orgName = asOrganization ? asOrganization.split(' ').slice(0, 3).join(' ') : '';
  const asnStr  = asn ? `AS${asn}${orgName ? ' ' + orgName : ''}` : orgName;
  return `${flag} ${geo}${asnStr ? ' (' + asnStr + ')' : ''}`.trim() || null;
}

export default {
  // HTTP handler – manual trigger via /run endpoint
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === '/run') {
      const location = locationFromRequest(request) || await detectLocation();
      const result   = await runMonitoring(env, location);
      return new Response(JSON.stringify(result, null, 2), {
        headers: { 'Content-Type': 'application/json' }
      });
    }
    return new Response(JSON.stringify({
      status: 'ok',
      message: 'Monitoring Worker is running. Use /run to trigger manually.'
    }), { headers: { 'Content-Type': 'application/json' } });
  },

  // Scheduled cron handler – no request object, detect location via CF trace
  async scheduled(event, env, ctx) {
    ctx.waitUntil((async () => {
      const location = await detectLocation();
      await runMonitoring(env, location);
    })());
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
      skipped: monitors.length - supported.length,
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
    return resp.status >= 200 && resp.status < 400
      ? { id: monitor.id, status: 'up',   response_time: rt, error: null }
      : { id: monitor.id, status: 'down', response_time: rt, error: `HTTP ${resp.status}` };
  } catch (e) {
    return {
      id: monitor.id,
      status: 'down',
      response_time: Date.now() - startMs,
      error: e.name === 'AbortError' ? `Timeout after ${CHECK_TIMEOUT_MS}ms` : e.message
    };
  }
}

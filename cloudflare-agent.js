/**
 * HTTP / cPanel Monitoring Agent - Cloudflare Worker
 *
 * 1. Fetches monitor list from node_api.php?action=get_monitors
 * 2. Performs HTTP availability checks (including cPanel resource usage)
 * 3. Posts results back to node_api.php?action=post_results
 *
 * Supports HTTP/HTTPS websites (type=web) and cPanel resource monitors (type=cpanel).
 *
 * Deploy: wrangler deploy (from this directory)
 */

const CHECK_TIMEOUT_MS = 8000;
const SUPPORTED_TYPES = ['web', 'cpanel'];

// IATA data center code → [city, ISO country] (Cloudflare major PoPs).
// The country comes from here and nowhere else: the colo is the one thing
// that says where the Worker ran. Codes as Cloudflare's trace prints them
// (Berlin is TXL there, Bucharest OTP); cross-checked against the PoP list
// on cloudflarestatus.com.
const COLO = {
  AMS:['Amsterdam','NL'],ARN:['Stockholm','SE'],ATL:['Atlanta','US'],
  BCN:['Barcelona','ES'],BEG:['Belgrade','RS'],BER:['Berlin','DE'],
  BKK:['Bangkok','TH'],BOM:['Mumbai','IN'],BRU:['Brussels','BE'],
  BUH:['Bucharest','RO'],CDG:['Paris','FR'],CWB:['Curitiba','BR'],
  DEL:['New Delhi','IN'],DFW:['Dallas','US'],DUB:['Dublin','IE'],
  DUS:['Düsseldorf','DE'],EWR:['Newark','US'],EZE:['Buenos Aires','AR'],
  FCO:['Rome','IT'],FRA:['Frankfurt','DE'],GIG:['Rio de Janeiro','BR'],
  GRU:['São Paulo','BR'],HAM:['Hamburg','DE'],HKG:['Hong Kong','HK'],
  IAD:['Washington DC','US'],IAH:['Houston','US'],ICN:['Seoul','KR'],
  IST:['Istanbul','TR'],JNB:['Johannesburg','ZA'],KHI:['Karachi','PK'],
  KIX:['Osaka','JP'],LAX:['Los Angeles','US'],LHR:['London','GB'],
  LIM:['Lima','PE'],LIS:['Lisbon','PT'],MAA:['Chennai','IN'],
  MAD:['Madrid','ES'],MAN:['Manchester','GB'],MEL:['Melbourne','AU'],
  MEX:['Mexico City','MX'],MIA:['Miami','US'],MNL:['Manila','PH'],
  MRS:['Marseille','FR'],MUC:['Munich','DE'],NRT:['Tokyo','JP'],
  ORD:['Chicago','US'],OSL:['Oslo','NO'],OTP:['Bucharest','RO'],
  PHX:['Phoenix','US'],PNQ:['Pune','IN'],PRG:['Prague','CZ'],
  QRO:['Queretaro','MX'],RUH:['Riyadh','SA'],SCL:['Santiago','CL'],
  SEA:['Seattle','US'],SFO:['San Francisco','US'],SIN:['Singapore','SG'],
  SJC:['San Jose','US'],SLC:['Salt Lake City','US'],SOF:['Sofia','BG'],
  SYD:['Sydney','AU'],TLV:['Tel Aviv','IL'],TPE:['Taipei','TW'],
  TXL:['Berlin','DE'],VIE:['Vienna','AT'],WAW:['Warsaw','PL'],
  YUL:['Montreal','CA'],YVR:['Vancouver','CA'],YYZ:['Toronto','CA'],
  ZRH:['Zürich','CH'],
};

const EDGE_UNKNOWN = '🌐 Cloudflare Edge (AS13335 Cloudflare)';

function countryFlag(code) {
  if (!code || code.length !== 2) return '🌐';
  return String.fromCodePoint(...[...code.toUpperCase()].map(c => 0x1F1E6 + c.charCodeAt(0) - 65));
}

/**
 * Detect location from Cloudflare's own trace endpoint.
 * Returns e.g. "🇩🇪 Frankfurt, DE (AS13335 Cloudflare)"
 */
async function detectLocation() {
  try {
    // Only `colo` (the PoP that served THIS worker invocation) is used. The
    // trace's `loc` is the country of the client IP, and inside a Worker the
    // client is the Worker's own egress IP, geolocated as US wherever it runs:
    // it put a US flag on Singapore, Warsaw and every other colo.
    const traceResp = await fetch('https://cloudflare.com/cdn-cgi/trace', {
      signal: AbortSignal.timeout(4000)
    });
    const traceText = await traceResp.text();
    const kv = Object.fromEntries(
      traceText.trim().split('\n').map(l => l.split('='))
    );
    const colo = kv['colo'] || '';
    // No colo (an error page instead of a trace) says nothing about where we
    // ran, and the label is shown publicly - no empty or made-up place.
    if (!/^[A-Z]{3}$/.test(colo)) return EDGE_UNKNOWN;
    // A colo missing from the map keeps its code and gets the neutral flag
    // rather than a guessed country; add it to COLO when it shows up.
    const [city, cc] = COLO[colo] ?? [colo, ''];
    const geo = [city, cc].filter(Boolean).join(', ');
    return `${countryFlag(cc)} ${geo} (AS13335 Cloudflare)`;
  } catch (e) {
    return EDGE_UNKNOWN;
  }
}

export default {
  // HTTP handler – manual trigger via /run endpoint
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === '/run') {
      // Same label as the cron run. request.cf describes whoever called /run
      // (their city, country and ISP), not where the checks are made from.
      const location = await detectLocation();
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
      headers: { 'User-Agent': 'MonitorAgent/1.0 (Cloudflare-Worker-Agent)' }
    });
    clearTimeout(timer);
    const rt = Date.now() - startMs;
    
    if (resp.status >= 200 && resp.status < 400) {
      if (monitor.type === 'cpanel') {
        try {
          const bodyData = await resp.json();
          if (bodyData && bodyData.status === 'ok') {
            return {
              id: monitor.id,
              status: 'up',
              response_time: rt,
              error: null,
              details: {
                disk: bodyData.disk,
                memory: bodyData.memory,
                processes: bodyData.processes,
                database: bodyData.database,
                bandwidth: bodyData.bandwidth,
                postgresql: bodyData.postgresql
              }
            };
          } else {
            return { id: monitor.id, status: 'down', response_time: rt, error: 'Chyba v cPanel JSON: ' + (bodyData ? bodyData.message : 'Neznámá chyba') };
          }
        } catch (jsonErr) {
          return { id: monitor.id, status: 'down', response_time: rt, error: 'Chyba parsování JSON statistik: ' + jsonErr.message };
        }
      }
      return { id: monitor.id, status: 'up', response_time: rt, error: null };
    } else {
      return { id: monitor.id, status: 'down', response_time: rt, error: `HTTP ${resp.status}` };
    }
  } catch (e) {
    return {
      id: monitor.id,
      status: 'down',
      response_time: Date.now() - startMs,
      error: e.name === 'AbortError' ? `Timeout after ${CHECK_TIMEOUT_MS}ms` : e.message
    };
  }
}

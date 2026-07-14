/**
 * Blood Kings Status Monitoring - Cloudflare Worker Agent
 * 
 * Tento Worker automaticky:
 * 1. Stáhne seznam monitorů z node_api.php?action=get_monitors
 * 2. Provede HTTP/HTTPS testy dostupnosti
 * 3. Odešle výsledky zpět na node_api.php?action=post_results
 * 
 * Nasazení:
 *   cd status/worker
 *   npx wrangler deploy
 * 
 * Cloudflare Worker neumí raw TCP, takže testuje pouze HTTP/HTTPS monitory.
 * Pro Minecraft, TeamSpeak a port-check použijte Python agenta (agent.py) na VPS.
 */

const WORKER_LOCATION = '🌐 Cloudflare Edge';
const CHECK_TIMEOUT_MS = 8000;
const SUPPORTED_TYPES = ['web'];

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === '/run') {
      const result = await runMonitoring(env);
      return new Response(JSON.stringify(result, null, 2), {
        headers: { 'Content-Type': 'application/json' }
      });
    }
    return new Response(JSON.stringify({
      status: 'ok',
      message: 'Blood Kings Monitoring Worker. Spustte /run pro manualni beh.'
    }), { headers: { 'Content-Type': 'application/json' } });
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(runMonitoring(env));
  }
};

async function runMonitoring(env) {
  const apiUrl = env.API_URL;
  const apiKey = env.API_KEY;

  if (!apiUrl || !apiKey) {
    return { error: 'Chybi NODE_API_URL nebo NODE_API_KEY.' };
  }

  let monitors = [];
  try {
    const resp = await fetch(`${apiUrl}?action=get_monitors&key=${encodeURIComponent(apiKey)}`, {
      signal: AbortSignal.timeout(10000)
    });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const data = await resp.json();
    monitors = data.monitors || [];
  } catch (e) {
    return { error: `Nepodarlo se nacist monitory: ${e.message}` };
  }

  const supported = monitors.filter(m => SUPPORTED_TYPES.includes(m.type));
  const results = await Promise.all(supported.map(checkMonitor));

  if (results.length === 0) {
    return { status: 'ok', message: 'Zadne HTTP monitory k testovani.', total: monitors.length };
  }

  try {
    const resp = await fetch(`${apiUrl}?action=post_results&key=${encodeURIComponent(apiKey)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ location: WORKER_LOCATION, results }),
      signal: AbortSignal.timeout(15000)
    });
    const data = await resp.json();
    return { status: 'ok', checked: results.length, skipped: monitors.length - results.length, server_response: data };
  } catch (e) {
    return { error: `Odeslani selhalo: ${e.message}`, results };
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
      headers: { 'User-Agent': 'BloodKingsMonitor/1.0 (Cloudflare Worker)' }
    });
    clearTimeout(timer);
    const rt = Date.now() - startMs;
    if (resp.status >= 200 && resp.status < 400) {
      return { id: monitor.id, status: 'up', response_time: rt, error: null };
    }
    return { id: monitor.id, status: 'down', response_time: rt, error: `HTTP ${resp.status}` };
  } catch (e) {
    return {
      id: monitor.id, status: 'down',
      response_time: Date.now() - startMs,
      error: e.name === 'AbortError' ? `Timeout po ${CHECK_TIMEOUT_MS}ms` : e.message
    };
  }
}

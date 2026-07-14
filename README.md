# HTTP Monitoring Agent

Two monitoring agents in one repo — both use the same secrets, configured once in GitHub.

## Agents

| Agent | Trigger | Tests |
|-------|---------|-------|
| GitHub Actions (`monitor.yml`) | every 5 min | HTTP/HTTPS |
| Cloudflare Worker (`bloodkings-monitor.js`) | every 5 min (cron) | HTTP/HTTPS |

## Setup (one-time)

Add these secrets under **Settings → Secrets and variables → Actions**:

| Secret | Description |
|--------|-------------|
| `API_URL` | Node API endpoint, e.g. `https://example.com/node_api.php` |
| `API_KEY` | Authentication key from the monitoring admin panel |
| `CLOUDFLARE_API_TOKEN` | CF API token with **Workers Scripts:Edit** permission |
| `CLOUDFLARE_ACCOUNT_ID` | Your Cloudflare account ID |

On every push to `main`, the `deploy-worker.yml` workflow automatically deploys the
Cloudflare Worker and pushes `API_URL` / `API_KEY` to it as Worker secrets.
No manual `wrangler` commands needed.

## Limitations

Only `web` type monitors (HTTP/HTTPS) are supported.
TCP ports, game servers etc. require a VPS-based agent.

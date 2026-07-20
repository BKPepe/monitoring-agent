# Monitoring Agents

Two different kinds of agent live in this repo, because they measure two different
things and run in two different places. Both report back to the same self-hosted
[status dashboard](https://github.com/BKPepe/monitoring) (see `apps/status/`), but
through separate API endpoints.

## 1. Distributed HTTP probes (this directory)

Check whether a **web/HTTP(S) target is reachable from the outside**, from several
independent network locations at once — the "is my site up, and from where does it
look down?" question. Two probes, same secrets, configured once in GitHub:

| Agent | Trigger | Tests |
|-------|---------|-------|
| GitHub Actions (`monitor.yml`) | every 5 min | HTTP/HTTPS |
| Cloudflare Worker (`cloudflare-agent.js`) | every 5 min (cron) | HTTP/HTTPS |

Both post results to `node_api.php` (the "Distributed Node API" on the status
dashboard) and both auto-detect their own runner location (city/country/ASN) so the
dashboard can show latency broken down per region.

### Setup (one-time)

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

**Limitation:** only `web` type monitors (HTTP/HTTPS) are supported here - see below
for TCP ports, game servers, and host-level metrics.

## 2. VPS host-metrics agents (`vps-agent/`)

Run **inside** a server you own and report **its own** CPU/RAM/disk usage, uptime,
listening ports, running processes and (optionally) game-server/process health -
things an outside HTTP probe can't see. Pick whichever fits the host:

| Agent | Runtime | Notes |
|-------|---------|-------|
| `agent.py` | Python 3, no dependencies | Cron every 5 min; supports self-update |
| `agent.sh` | Bash/sh, no dependencies | Same as above, for hosts without Python |
| `agent.ps1` | PowerShell 5.1+ | Windows, via Task Scheduler |
| `docker-compose.agent.yml` | Docker | Runs `agent.py` with `pid: host` so it reports the **host's** metrics, not the container's |

All four report to `agent_api.php` (a different endpoint than the HTTP probes
above), authenticated with a per-monitor `AGENT_KEY` issued by the dashboard's
admin panel. See `apps/status/README.md` for full installation instructions for
each variant, and the "Self-Updates" section for how the opt-in auto-update flow
(checksum-verified, atomic replace) works across all four.

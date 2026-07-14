# HTTP Monitoring Agent

GitHub Actions workflow that runs HTTP availability checks every 5 minutes
and reports results to a compatible status monitoring API.

## Secrets

| Secret | Description |
|--------|-------------|
| `API_URL` | Node API endpoint, e.g. `https://example.com/node_api.php` |
| `API_KEY` | Authentication key from the monitoring admin panel |

## Limitations

Only `web` type monitors (HTTP/HTTPS) are supported.
TCP ports, game servers etc. require a VPS-based agent.

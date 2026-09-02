# Agent end-to-end tests

Syntax checks and lints say a script parses; these say it *works*. Each
harness runs an agent with `--dry-run` inside a container and asserts on the
JSON it prints - valid JSON, honest nulls on the first run, deltas on the
second, parsers reading the right columns.

| Script | What runs | Needs |
| --- | --- | --- |
| `run_linux_e2e.sh` | `agent.sh` and `agent.py` in Debian (real `/proc`, real `ps`), twice, the second run under load | docker, python3 |
| `run_openwrt_e2e.sh` | `agent_openwrt.sh` in busybox (ash, busybox awk/sed) with canned `wg`, `mwan3`, `tc`, `uci`, `logread`, `iwinfo`, `nft`, `ubus`, `ping` from `openwrt-stubs/bin` | docker, python3 |

The stub outputs are what the real tools print (`wg show all dump`,
`mwan3 status`, `tc -s qdisc`, ...); when a tool changes its format, update the
stub and the assertion together.

`agent.ps1` has no runtime here - the monitoring repository's quality gate
parses it with `pwsh`.

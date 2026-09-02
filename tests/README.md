# Agent end-to-end tests

Syntax checks and lints say a script parses; these say it *works*. Each
harness runs an agent with `--dry-run` inside a container and asserts on the
JSON it prints - valid JSON, honest nulls on the first run, deltas on the
second, parsers reading the right columns.

| Script | What runs | Needs |
| --- | --- | --- |
| `run_linux_e2e.sh` | `agent.sh` and `agent.py` in Debian (real `/proc`, real `ps`), twice, the second run under load, against a stand-in TeamSpeak ServerQuery on 10011 (`linux/fake_ts3.py`) - and once more with `python3` made unusable, so the bash agent's `nc` transport is exercised too | docker, python3 |
| `run_openwrt_e2e.sh` | `agent_openwrt.sh` in busybox (ash, busybox awk/sed) with canned `wg`, `mwan3`, `tc`, `uci`, `logread`, `iwinfo`, `nft`, `ubus`, `ping` from `openwrt-stubs/bin` | docker, python3 |

The stub outputs are what the real tools print (`wg show all dump`,
`mwan3 status`, `tc -s qdisc`, ...); when a tool changes its format, update the
stub and the assertion together.

`agent.ps1` has no runtime here - the monitoring repository's quality gate
parses it with `pwsh`.

The TeamSpeak stub earns its keep: that query had never been run by any test.
The first run of it showed the bash agent asking over bash's socket redirection
(a hosting malware scanner quarantined the whole file for that shape) and the
Python agent assuming the server's greeting arrives in exactly two packets.

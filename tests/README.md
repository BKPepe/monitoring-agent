# Agent end-to-end tests

Syntax checks and lints say a script parses; these say it *works*. Each
harness runs an agent with `--dry-run` inside a container and asserts on the
JSON it prints - valid JSON, honest nulls on the first run, deltas on the
second, parsers reading the right columns.

| Script | What runs | Needs |
| --- | --- | --- |
| `run_linux_e2e.sh` | `agent.sh` and `agent.py` in Debian (real `/proc`, real `ps`), twice, the second run under load, against a stand-in TeamSpeak ServerQuery on 10011 (`linux/fake_ts3.py`) - and once more with `python3` made unusable, so the bash agent's `nc` transport is exercised too | docker, python3 |
| `run_openwrt_e2e.sh` | `agent_openwrt.sh` in busybox (ash, busybox awk/sed) with canned `wg`, `mwan3`, `tc`, `uci`, `logread`, `iwinfo`, `hostapd_cli`, `iw`, `smartctl`, `df`, `nft`, `ubus`, `ping`, `openssl` from `openwrt-stubs/bin` and a fake `/sys` + `/proc` from `openwrt-stubs/mkroot.sh`; six payload runs, then the scenario and hardening runs on canned server answers | docker, python3 |

The stub outputs are what the real tools print (`wg show all dump`,
`mwan3 status`, `tc -s qdisc`, ...); when a tool changes its format, update the
stub and the assertion together.

### The OpenWrt harness: a real router as the fixture

The Wi-Fi, disk and WAN stubs serve what the owner's Turris Omnia really
printed (`openwrt-stubs/omnia/`, its `README.md` names the origin of every
file and what is synthesized). Identifiers are masked and must stay masked.
Around the real router stand synthetic devices, one for each parser branch it
cannot show: a sleeping USB disk, an unknown USB bridge, an NVMe with a
critical warning, a disk without a drive database entry, a 6 GHz radio, an AP
with nobody on it.

- **Fake root.** `/sys` and `/proc` cannot be stubbed through `PATH`, so the
  agent has a seam: with `--dry-run` AND `STATUS_TEST_ROOT=<dir>` the
  collectors that name `BK_SYS` / `BK_PROC` read below `<dir>`.
  `mkroot.sh DIR [emmc]` builds the tree; the `emmc` variant is a router with
  eMMC and a disk whose `smartctl` ignores TERM.
- **No jsonfilter.** The image has none and a stock router need not have one:
  `smartctl` answers in its flat `--json=g` form and `ubus` output is read
  line by line, both with awk or `read`. JSON parsing CI never runs is not
  shipped.
- **Stubs behave like the tool, including its refusals.** `iwinfo` takes one
  command per call and answers a batched call the way the real CLI does
  (stderr, exit 1, nothing on stdout); `hostapd_cli` prints nothing and exits 0
  for an empty AP and exits 255 without a socket; `smartctl` prints decoy
  identifiers unless `-q noserial` is given and exits 3 for a sleeping disk
  only when asked with `-n standby,3`; `nslookup` refuses with no delay at all
  under `BK_STUB_DNS=fail`, which is the point of the DNS check - three
  milliseconds are not a latency. A wrong stub makes every parser check
  built on it wrong too, so `openwrt-stubs/selftest.sh` runs BEFORE the first
  agent run and pins those refusals and the fake root itself; its result is
  `out/stub_selftest.txt` and one assertion requires every line to be `ok`.
- **Runs.** `r1` (first run), 11 s pause and moved disk counters, `r2`
  (deltas), `r2b`, `r3` (no netifd interface, no `hostapd_cli`, `smartctl`,
  `iw`), `r4` (eMMC root), `r5` (a SMART lock held by a live process). The 11 s
  are real: the agent believes a Wi-Fi survey delta only when that much wall
  clock has passed, and the gate is not loosened for CI. Each radio's survey
  says something different on purpose: `phy0-ap0` is the real capture and
  measures 3.5 %, `wlan0` jumps by an impossible 60,000 ms and must stay
  `warming_up`, `wlan7` was busy for 75 % of its life but only 10 % over the
  last sample, so a reading of the absolute counters cannot pass as a delta,
  and `phy3-ap0` answers nothing at all, which is `unsupported`. After `r5` the
  private directory is removed and the call logs move to `out/core/`: checks
  that count calls ("asked once, then cached") read `core/`, checks that say
  "never" read both sets. Every later run (`w...`) starts on a clean private
  directory; all of them are dry runs.
- **The WAN walk gets one run per branch.** The Omnia has one uplink and can
  show one shape of it at a time, so `BK_STUB_WAN` picks which line netifd
  reports and `mkroot.sh` builds the matching netdev chain: `wpppoe` is the
  owner's PPPoE over VLAN 848 over `eth2` (the rate is readable on the VLAN,
  the port is the one below it), `wwalk1` the port itself, `wwalk2` a bridge
  over ONE port, `wwalk3` a bridge over TWO (no single port: every port
  counter must be null), `wwalk4` a lone ppp netdev that answers nothing, and
  `wwalk5` a DSA user port whose carrier is down at `-1` above a conduit at
  1000 - the number that must never be inherited. `eth2` carries the real byte
  counters of the capture and four raised error counters, while the VLAN above
  it drops 174 frames of its own, which is what a reading off the wrong netdev
  looks like. The flap counter is pinned the same way: `eth2` has seen four
  carrier losses and the DSA port seven, while every virtual netdev above them
  stays at 0, so the step metric `wan_link_flaps` cannot quietly be fed from
  the device that only carries the traffic.
- **What the 11 s between `r1` and `r2` move.** Not only the disk counters:
  the second `/proc/stat` sample (core 0 drowning in softirq, so the busiest
  core is 98.2 % while the average of the same snapshot is 52.4 %), the busy
  conntrack copy, the uptime from `1000.00` to `1011.00` - the rate is
  measured against THAT, never against the clock - and 15.4 MB received plus
  2.2 MB sent on the WAN device, which is the 11.2 / 1.6 Mbit/s the payload
  has to show. `r2b` follows with nothing moved at all, and every one of those
  values has to go back to null.
- **conntrack in three files.** `proc/net/stat/nf_conntrack` is the real capture
  of the owner's router, where columns 10-12 are all zero - a measured zero,
  which is not the same as null. Its busy copy carries 3 / 1 / `0x12` over two
  CPUs plus a non-zero `insert` and `icmp_error` beside them, so a column read
  one to the side or a decimal reading of the hex (12 instead of 18) both
  show. `r3` runs with the file moved away: null, never zero, and the
  `wwalk` runs get a third file whose header names other counters in
  another order (no `insert_failed` at all): its hex is not read at all,
  because the header line is what says where the three columns are.
- **What each disk pins.** `sda` is the owner's Kingston SSD and carries the
  real SMART capture (67 C, 24,750 h, 227 unclean shutdowns, 420 GiB written
  through attribute 241, wear 0 from 231, no attribute 198 - so that field must
  come back `null`, not 0). `sdb` is a rotating USB disk that is asleep: in `r1`
  nobody may touch it (`idle_skipped`), in `r2` its counters move and it is
  probed, and `-n standby,3` gets exit 3 back. `sdc` hides behind a USB bridge
  smartctl does not know (`unsupported`). `sdd` is the same SSD WITHOUT a drive
  database entry, where 241 and 231 carry generic names that must not be
  interpreted. `nvme0n1` reports a critical warning (`failing`). `sde`, in the
  eMMC root only, ignores TERM, so the watchdog has to reach for KILL. The
  mount of `sdb1` has a space, a `#` and quotes in it, because a mount point is
  a name a person chose and it has to survive into valid JSON.
- **Two SMART scenarios after the payload runs.** `wsmart` plants a two-hour-old
  reading for `sdb` and disk counters that say it is working, so it really is
  probed and really answers "standby": the previous values and their time must
  survive. `wlock` plants a lock held by a live process and an empty cache, so
  every disk is due - and not one `smartctl` may start.
- **Speed test results and the ack.** `/srv/speed` (what the `uci` stub reports
  as `librespeed.client.data_dir`) holds four result files: the Go client's
  1850.23 Mbit/s with a `client` block, a public address and a `share` link
  inside it; the owner's Rust port, whose `tls` block is the only evidence in
  a file of which tool wrote it; a half-finished measurement with no `upload`;
  and a failed run with no speed at all, which is not a result. The hard-coded
  default `/tmp/librespeed-data` holds one file that only a run whose `uci`
  cannot answer may ever send, and `/srv/speed60` holds sixty, of which fifty
  leave per report. The addresses in the fixtures are from RFC 5737's
  documentation ranges and are there on purpose: "the client block never
  leaves the router" is only provable when there is something to leak.
  `wack1..wack6` drive the hand-over through the response seam - a report that
  never arrived, a bare 200, an ack naming the second of three items, an ack
  for a timestamp that was never sent, and the one that finally commits.
- **The path state.** `wpath1..wpath8` each start on an empty private
  directory, because the answer is cached for an hour and a second run would
  only read the cache back: the owner's line with `ethtool` present, a driver
  whose MIB names neither ring counter, offloading configured off with no
  flowtable and the uci label `0`, an image with no `nft`, `tc` or `ethtool`,
  a router without `/etc/config/sqm`, one whose `ubus` answers nothing at
  all, one whose two gigabit cables are out, and one (`BK_STUB_SQM=off`)
  whose SQM queue names the WAN port itself and is switched off - the
  `enabled` flag is what the other runs cannot pin, because there the stale
  section sits on another device anyway. The cables-out run
  (`BK_STUB_UBUS_DEV=lan1only`, the same capture with `lan0` and `lan4` left
  without carrier and without a `speed` line) is what tells a capability from
  a current state: the fastest LINKED port is then `lan1` at 100 while every
  port still SUPPORTS 1000. On the capture as it was taken the two answers
  agree, so a `lan_port_cap_mbit` read off `speed` would look right.
  The payload runs prove the other half: six runs, one `uci` read of each
  option and one `ubus` device dump between them. `tc` and `ethtool` are NOT
  applets of the image (the owner's router has neither), so removing the stub
  really removes the tool.
- **The gap runs `wfw1..3`, `wdns1`/`wdns3`, `wrun1..7`.** What "the firewall
  is up" is read from: the `nft` stub serves three rulesets - fw4 (every other
  run), `BK_STUB_NFT=foreign` (mwan3's table and nothing else) and
  `BK_STUB_NFT=empty` (nft answers, the kernel is empty) - plus a run with no
  `nft` at all, where the image also has no `iptables` applet. A
  `/etc/init.d/firewall` stub answers `enabled` in ALL of them, on purpose: a
  fall-back to it would be visible as a `true` where the rules are not loaded.
  The DNS probe: the `nslookup` stub resolves by default and refuses instantly
  with `BK_STUB_DNS=fail`, and `wdns3` removes the stub AND busybox's own
  applet, because "no resolver client" cannot be built while `/bin/nslookup`
  exists. The agent's own clock: `wrun1` meets a `run.lock` held by a live
  process and writes no payload at all; `wrun2`/`wrun3`/`wrun4` go through the
  response seam (`000`, then two 200s) and show the skip counters rise and
  then clear; `wrun5` runs with `BK_STUB_UPTIME_BUMP=1`, where the `logread`
  stub - the one command a full run makes exactly once, between the two uptime
  reads - moves the fake router's uptime 4.20 s forward, so `agent_run_ms` is
  exactly 4200; `wrun6` reads that same number back as `agent_prev_total_ms`
  from the EXIT trap, and `wrun7` runs with no `proc/uptime` at all.
- **Pending checks.** `assert_openwrt_payload.py` may list checks in `PENDING`
  while the collector that satisfies them is not merged yet. A pending check
  that passes fails the run, and `BK_E2E_STRICT=1` fails every pending check;
  a release needs the list empty.

### Hardening runs

After the payload runs the OpenWrt harness goes on with the hardening runs
(`openwrt-stubs/runs-g28.sh`): a planted identity cache must run nothing, the
kept last payload must be 0600 and carry no key, and remote actions must be
allow-listed, single-use and path-safe. Remote actions come from the server's
answer, and a dry run stops before the POST, so the agent has one test seam:
with `--dry-run` AND `STATUS_TEST_RESPONSE=<file>` (line 1 = HTTP code, the
rest = body) it prints the payload and then runs its normal after-the-answer
path on that file. Nothing is ever POSTed: action results go to
`<file>.results`. The `openssl` stub answers the HMAC with the digest the
harness chose (`BK_STUB_HMAC`) and logs what it was asked to sign; the action
targets (`/sbin/ifdown`, `/sbin/reboot`, `/etc/init.d/dnsmasq`, ...) are
copies of `openwrt-stubs/action-target.sh` that only log the call. Without
`--dry-run` the variable is ignored; one assertion greps the agent for that.

`agent.ps1` has no runtime here - the monitoring repository's quality gate
parses it with `pwsh`.

The TeamSpeak stub earns its keep: that query had never been run by any test.
The first run of it showed the bash agent asking over bash's socket redirection
(a hosting malware scanner quarantined the whole file for that shape) and the
Python agent assuming the server's greeting arrives in exactly two packets.

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

### Optional packages on OpenWrt, and what each one unlocks

The OpenWrt agent runs on a stock image and asks for nothing. Three packages
are not installed by default, and each one turns a group of values from
`null` into a measurement - never from `0` into a measurement, because what
cannot be read is reported as unknown:

| Package | Command | What it unlocks |
|---|---|---|
| `hostapd-utils` | `hostapd_cli` | per-station facts of every AP radio: the Wi-Fi generation mix (4/5/6/7), the 6 GHz operating classes behind `clients_6ghz_capable`, the WPA2 / WPA3 split and the weakest client's generation. Without it those come from `ubus` at best (no generation 7, no AKM, no operating classes) and are `null` otherwise |
| `smartmontools` | `smartctl` | the whole `smart` block of every disk: health verdict, temperature, power-on hours, unclean shutdowns, reallocated and pending sectors, wear and bytes written. The companion `smartmontools-drivedb` is what makes the vendor-specific attributes (wear, unsafe shutdowns, runtime bad blocks) readable at all |
| `iw` | `iw dev <radio> survey dump` | `busy_pct` and `busy_other_pct`, how much of the channel time was in use in the last minute and how much of it was somebody else's. Without the package the state is `not_installed` |

```sh
opkg update && opkg install hostapd-utils smartmontools smartmontools-drivedb iw
# on images whose package manager is apk (OpenWrt 24.10 and newer):
# apk add hostapd-utils smartmontools smartmontools-drivedb iw
```

`agent_tools` in every report says which of them the router has, so the
dashboard can name the missing package instead of warning about a value
nobody can measure.

### Wi-Fi 6E support of the clients (OpenWrt)

From 0.1.6 each Wi-Fi radio also reports `clients_6ghz_capable` and
`clients_caps_known`: how many connected stations list a 6 GHz operating class
(131-137, i.e. Wi-Fi 6E) and how many sent their list of operating classes at
all. The list comes from `hostapd_cli all_sta`, which ships in the
`hostapd-utils` package and is not installed on OpenWrt by default:

```sh
opkg update && opkg install hostapd-utils
```

Without it both values are `null` (unknown), never `0`. A station that sent no
list is left out of `clients_caps_known`, so "not capable" and "did not say"
stay apart.

From 0.1.7 the AP's own mode is taken into account, because hostapd only marks
a station `[HE]` while the AP itself runs HE (Wi-Fi 6) or newer: on such a radio
a station WITHOUT `[HE]` cannot be a 6 GHz client and is counted as known and
not capable, while on an older AP the same station stays unknown unless it sent
its operating classes. The list is read only up to the first `00` or `82`
delimiter byte - what follows is another band's history, not this station's
ability.

### What else every radio reports from 0.1.7 (OpenWrt)

The band comes from the frequency alone (2.4 / 5 / 6 GHz), never from a channel
number or a list of hardware modes, and it is `null` on a radio that reports no
frequency. Next to it: the HT mode as the card prints it (`HE80`, `VHT40`,
`NOHT`), the encryption class, the median and weakest signal of the connected
stations, the weakest signal-to-noise ratio, how many stations are at or below
-75 dBm, the mean transmit rate of the last frames, the generation mix
(Wi-Fi 4/5/6/7) and, with `hostapd-utils`, how many stations authenticate with
WPA2 and how many with WPA3.

The WPA2 / WPA3 count normally comes from the `AKMSuiteSelector` line of
`hostapd_cli all_sta`. Builds that do not print it are not counted as zero: on a
WPA2 or WPA2/WPA3 personal network a station that associated WITHOUT [MFP]
cannot be using SAE (WPA3 requires management frame protection), so it is
counted as WPA2; a station with [MFP] stays unknown, and on a mixed WPA/WPA2
network nothing is inferred at all, because there a station without [MFP] may
just as well be a WPA version 1 one.

Two values need a package of their own:

- `busy_pct` (how much of the channel time was in use) is a delta between two
  `iw dev <radio> survey dump` samples one run apart. The first run after a
  start, a channel change or a counter reset reports `busy_state:
  "warming_up"` and no number; a driver that reports no survey data for its own
  frequency reports `unsupported`; without the `iw` package, `not_installed`.
  It is never a zero that was not measured.
- `snr_min` is sent only for stations whose noise floor the driver knows.
  `iwinfo` prints `signal - noise` even when the noise is unknown, with a zero
  in its place, and that number is arithmetic, not a measurement.

### Disks and SMART (OpenWrt)

From 0.1.7 the agent reports the physical disks themselves, not only how full
a mount point is: the name, how the disk is attached (SATA, USB, NVMe, eMMC,
SD), the port, the sysfs model, the size, whether it spins, whether it is
removable, and its partitions joined to the `df` output by device. `loop*`,
`zram*`, `mtdblock*` and the eMMC boot and RPMB areas are not disks and never
appear. No serial number, WWN or CID is sent - the sysfs files that hold them
(`serial`, `wwid`, `vpd_pg80`, `cid`) are never opened, and `smartctl` is
always called with `-q noserial`. An eMMC additionally reports its wear levels
(`life_a`, `life_b`, `pre_eol`), which the card exposes as 1-11 and 1-3; the
code 0x00 means "not reported" and stays `null`.

The disk list is rebuilt only when it changes - a fingerprint of name and size
read with shell builtins - or once an hour, so an ordinary minute costs one
`awk` and no drive access at all.

With `smartmontools` installed every disk also carries a `smart` block:
temperature, power-on hours, power cycles, unclean shutdowns, reallocated,
pending and uncorrectable sectors, CRC errors, wear, bytes written and the
error and self-test log counts. What is deliberately NOT there matters as
much:

- Values whose meaning lives in the drive database - wear (231, 169, 202, 233,
  177), unclean shutdowns (174, 192), runtime bad blocks (183) - are sent only
  with `smartmontools-drivedb` installed AND when the attribute really carries
  that name. Without the database OpenWrt's smartctl calls attribute 241
  `Total_LBAs_Written` and 231 `Temperature_Celsius` whatever the drive counts
  there, and 183 is `SATA_Downshift_Count` on most drives.
- Attribute 241 is converted by its NAME (GiB, MiB, 32 MiB blocks or LBAs);
  device statistics are exact and win over it, and an NVMe reports its own
  counter. A fixed x 512 would turn 420 GiB written into 215 kB.
- The temperature is `temperature.current`, never the packed raw of attribute
  194 (on the owner's disk that number is 292058955843).
- An attribute the drive does not have is `null`, never 0.

The reading itself never happens inside the minute run. The run only decides
which disks are due and hands them to a detached `--smart-refresh` child,
which takes a lock of its own, reads one disk at a time and writes the cache
the next run merges. So the report never waits for a drive - busybox has no
`timeout` applet, and a hung USB bridge can hold `smartctl` for minutes. From
that follow the rules worth knowing:

- A disk is read at most once per `SMART_INTERVAL_MINUTES` (`agent_openwrt.cfg`,
  default and floor 60).
- A SPINNING disk that nobody is using is not read at all: waking it every hour
  is exactly the wear the check exists to watch. Its state is `idle_skipped`
  until the first minute its counters move, and `smartctl -n standby,3` is a
  second guard behind that.
- One `smartctl` may run for `SMART_TIMEOUT_SEC` (default 60, clamped 10-180),
  then it gets TERM, then KILL. A process that survives both keeps the lock:
  the disk is reported as `stuck`, nothing new is started against it, and the
  dashboard shows the hang instead of a silent gap.
- A disk that answers "in standby", or that cannot be read, keeps its previous
  values stamped with the time THEY were read. A sleeping disk is not a disk
  whose temperature suddenly became unknown.

`agent_tools` says what the router can measure at all: `smartctl`,
`smart_drivedb`, `hostapd_cli`, `iw`, `librespeed_cli`, `ethtool`, `tc`, which
package manager it has, how old the last SMART probe is and whether one is
running right now. It is the REASON a value is `null`, which lets the
dashboard offer an install hint instead of warning about a disk nobody can
read.

### The WAN port, its counters and the busiest core (OpenWrt)

From 0.1.7 the agent answers two different questions about the uplink instead
of one, because on a PPPoE or VLAN line they have two different answers.

- **`wan_link_mbit`** is the negotiated rate of the link. A VLAN, bridge or
  macvlan netdev answers `speed` by passing the question through to its real
  device, so the first netdev of the chain that answers at all is the right
  source of the rate - on this router `eth2.848` answers 2500, the same as the
  SFP port under it. A `-1` or a `0` is an answer too ("link down", "unknown")
  and the walk stops there: a dead DSA port must never inherit the fixed 1000
  of the conduit below it. Only when the read *fails* - a ppp netdev has no
  link settings at all - does the walk go one level down, through a single
  `lower_*` link, at most four levels.
- **`wan_link_dev`** is the physical port: the first netdev of that chain with
  a `device` symlink. Virtual netdevs have none, which is exactly what tells
  them apart. `wan_rx_errors`, `wan_tx_errors`, `wan_rx_dropped`,
  `wan_tx_dropped` and `wan_carrier_down_count` are read from THAT port and
  nowhere else. A bridge over two ports has no single port, so all of them
  stay null: a VLAN reports `0` dropped frames by construction (its kernel
  path fills only its own counters), and a zero nobody measured is not data.
  On a modem protocol (`qmi`, `mbim`, `ncm`, `modemmanager`, `3g`) both the
  rate and the port are null - a usbnet "speed" is a USB descriptor.

`wan_rx_dropped` is evidence, not an alarm: on this hardware it counts failed
skb allocations *and* frames of protocols nobody handles (LLDP, foreign VLAN
tags, PPPoE discovery from the access network), so it is far more often
benign junk than overload. The counters are sent as totals; the server turns
two reports into the step between them.

**`wan_rx_mbps` / `wan_tx_mbps`** are measured on the l3 device - the one that
carries the traffic, on PPPoE the ppp netdev and not the port under it -
against the previous run, in `wan-rate.state`. The elapsed time comes from the
uptime in centiseconds, never from the clock, so a router whose time jumps
cannot report a rate nobody transferred. The device name is part of that
state: after a failover the WAN device changes and a delta between two
different counters would charge a whole session to one minute. First run,
device change or a counter that went backwards: null.

**The busiest core.** `cpu` (the average over all cores) hides exactly the
case this release is about: one core pinned by the packet path while the other
idles. Every run collects the aggregate line and every `cpuN` line of
`/proc/stat` in one builtin loop - no `grep` fork - into `cores.now`, moving
the previous one to `cores.prev`, and one awk computes both from the same
snapshot, so `cpu` and `cpu_core_max_pct` can never describe two different
intervals. Reported: `cpu_cores`, `cpu_core_max_pct`, `cpu_core_max_index` and
`cpu_core_max_softirq_pct` (irq + softirq of that core; threaded NAPI and the
mt76 workers are charged to *system*, so the two numbers together are what
"the packet path is eating this core" looks like). The whole block is null on
the first run after a boot, when a counter went backwards, and when no core
moved at all - `cpu_cores` included, because a core count next to four nulls
reads as a measurement that failed silently.

**conntrack.** `conntrack_insert_failed`, `conntrack_drop` and
`conntrack_early_drop` are the per-CPU columns 10-12 of
`/proc/net/stat/nf_conntrack`, summed over the CPUs. They are three different
things and are never added up: `insert_failed` grows on confirm races and long
hash chains and is routine on a two-core router with RPS; `early_drop` counts
entries that were successfully evicted to make room, so nothing was refused;
only `drop` with a full table is a connection the router turned away. The file
is hexadecimal without a `0x` prefix and busybox awk cannot read hex, so the
sum is done in the shell with `$((0x..))`. No file, no numbers - null.

### Speed test results and what a 200 really means (OpenWrt)

The router runs `librespeed-cli` from cron and drops the result into
`librespeed.client.data_dir` (`/tmp/librespeed-data` when the option is not
set). `/tmp` is a ramdisk, so those files are gone after every reboot: the
agent's job is to get them off the router before that happens.

- **Speeds are Mbit/s.** 0.1.6 rescaled anything above 1000 as "bytes per
  second", which turned a 1850 Mbit/s result into 0.0148 Mbit/s. There is no
  such heuristic any more, and the server repairs the rows it damaged - which
  works only because 0.1.7 offers the whole directory again once (it deletes
  the old `/tmp` state file on the version change instead of migrating it).
- **The file names are the filter.** The name of a result file IS the
  measurement time, so one awk decides from the names alone which files are
  opened at all. At most 50 leave per report and the oldest go first, so a
  router that was offline for a week catches up in order.
- **A 200 is not a receipt.** The server wraps its speedtest INSERT in a
  try/catch so a broken result cannot bring telemetry ingestion down - it logs
  the failure and still answers 200. The answer therefore carries
  `speedtests_acked`: the newest item it dealt with (stored, already there, or
  rejected for good), echoed exactly as it was sent. The agent writes
  `pending.state` before the POST and advances its mark only up to that
  timestamp; a 200 without the key, or with a timestamp this report never
  sent, commits nothing and everything is offered again. The unique key on the
  server makes that idempotent.
- **What is sent per result:** the measurement time, the four numbers, the
  server NAME, the transferred bytes, and `started_by: "turris"`. Never the
  `client` block (it holds the public address and the ISP), never `share`,
  never the backend URL with its query string. `tool` is filled only when the
  file itself proves which program wrote it - a `tls` block is the owner's
  Rust port; a file without one stays null instead of being guessed.
- **`speedtest_active`** is an INTERVAL flag, not an instant one: a report
  covers the last minute, so a test that ended twenty seconds ago still owns
  its CPU numbers. It is true when a result is new in this run's listing or
  `pidof librespeed-cli` answers. The server uses it to keep a test out of CPU
  alerts and anomaly comparisons.

### The path a packet takes through the router (OpenWrt)

`wan_path` is one object, refreshed once an hour into
`$BK_PRIVATE_DIR/wan-path.cache` and sent from there on every run: it is
configuration and switch state, which changes when somebody changes it, not
from minute to minute. Reading it every minute would cost a uci fork per
option, a `tc` call per queue and an `ubus` dump of every netdev.

- **Offloading.** `flow_offloading` / `flow_offloading_hw` are what uci says;
  `flowtable_active` is what the loaded nftables ruleset says, taken from the
  dump the firewall counters already fetched. Configuration and reality are
  two answers, and a router can have the first without the second.
- **Packet steering.** `packet_steering` is the raw uci value, a LABEL and
  never a boolean: in this tree an unset option means steering is ON and only
  `0` disables it, while on 22.03/23.05-based systems unset means OFF. The
  answer the recommendations read is `packet_steering_active`, the runtime
  mask of EVERY `rx-*/rps_cpus` queue of the WAN port - mvneta has several and
  the init script fills them all. No queue file, or no physical port, and it
  is null: unknown is not "switched off".
- **Ring drops.** `wan_rx_ring_drops` is `rx_discard` + `rx_overrun` from
  `ethtool -S` on the port. `ethtool` is not in every image (this router does
  not have it), and other drivers name those counters differently; without
  both names the answer is null, never 0.
- **SQM.** Every ENABLED queue whose `interface` is a device of the WAN chain
  - the l3 device, every netdev the port walk passed, and the port itself -
  so a queue configured on `eth2` is found for a WAN that runs over
  `pppoe-wan`, and the other way round. 0.1.6 read `sqm.@queue[0]`, which is
  "the first section in the file"; on this router that is a disabled leftover
  on the LAN conduit. A configured rate of `0` means that direction is not
  shaped and is null, not 0 kbit/s. Drops come from two qdiscs: the device
  itself for egress and SQM's `ifb4<device>` for ingress (the kernel cuts that
  name to 15 bytes, so the lookup does too). `sqm: []` means "checked, no
  queue on the WAN path"; `sqm: null` means it could not be checked, and
  `sqm_enabled` is null on a router with no SQM configuration at all.
- **The LAN side.** One `ubus call network.device status` an hour, parsed with
  `read` - not with `jsonfilter`, which the image does not carry and which no
  test here runs. Only members of the LAN bridge with devtype `dsa` or
  `ethernet` count, so a USB LTE stick that is an "ethernet" device is not a
  LAN port. `lan_port_max_mbit` is the fastest port linked RIGHT NOW (a lone
  100 Mbit printer makes it 100); `lan_port_cap_mbit` is what those ports can
  do at all, taken from netifd's `link-supported` list and never derived from
  a negotiated rate; `lan_conduits[]` names the DSA conduit they share with
  its own rate, because five gigabit ports behind one gigabit conduit share
  1 Gbit between them.

### The LAN switch, port by port (OpenWrt, 0.1.8)

`lan_ports` answers three questions about the wired side: which ports carry a
link, which are idle, and how many devices sit behind each one. Unlike
`wan_path` it is read on EVERY run - a cable is pulled and a laptop moves
between minutes, not between hours - so the one `ubus call network.device
status` per run serves both, and the hourly block reuses that same walk
instead of asking again. The whole walk - the 27 kB dump plus the forwarding
database - measures about 20 ms of shell on x86, so it fits the runtime budget
several times over on the router's own CPU.

- **Counts only, never identifiers.** A per-port device COUNT is not personal
  data. MAC addresses, hostnames and IP addresses stay on the router: the
  MACs are read by an `awk` that prints nothing but `dev count`, and a named
  device list is a separate, opt-in feature. Nothing here is hashed and sent
  either - a hashed MAC is still an identifier.
- **Per port**: `link`, the negotiated `speed_mbit` and `duplex`, `max_mbit`
  (what the port itself supports, from `link-supported`), `partner_max_mbit`
  (what the other end advertises) and `clients`. A port with no carrier
  prints no `speed` at all, so its rate and duplex are null - never 0, which
  would read as a measurement nobody took. `partner_max_mbit` is what lets the
  app say that lan1 at 100 Mbit is the other end's limit and not a fault.
- **`conduits[]`** carries the DSA conduit with its own rate. On this hardware
  every wired client shares one 1 Gbit link to the CPU, and that, not the
  port, is the real ceiling.
- **The counts** come from `bridge fdb show br <bridge>`. Not a client, and
  dropped: `permanent` rows (the bridge's and the ports' own addresses), the
  `vlan 4095 ... self` rows DSA keeps for its CPU port, the multicast groups
  `33:33:*` and `01:00:5e:*` and broadcast. One MAC learnt in several VLANs is
  one device. Only bridge members with devtype `dsa` are ports: the radios are
  bridge members too (and their clients are counted per radio elsewhere), and
  a USB LTE stick is an "ethernet" device that is not in the bridge at all.
  The number is what the bridge has LEARNT, so the app should word it that way:
  a port with a link and `clients: 0` holds a device that has not spoken since
  the bridge last forgot it, not necessarily an empty socket.
- **Null, never an empty list**, when the router cannot answer: no ubus dump,
  no LAN bridge, no `bridge` command (`/usr/sbin/bridge` is looked at directly
  as well, because cron hands a job a PATH without sbin on some builds), or a
  switch that is not DSA - there the kernel does not say which physical port a
  frame came in on. An empty list would claim there are no devices anywhere,
  which is a different statement.

### The error lines behind the log count (OpenWrt, 0.1.8)

`log_errors_24h` counts the error lines among the last 500 lines of the log.
The name is historic: logd is a ring buffer, and 500 of its lines can be ten
minutes or three days. From 0.1.8 the report also says what the count covers
and what it counted:

- **`log_window_secs`**: seconds from the oldest of those lines to now, so the
  app can say "in the last N hours". Null when no line has a readable time.
- **`log_errors_recent`**: the newest 5 distinct error lines, newest first, as
  `{"ts", "prog", "msg", "count"}`. The count's own regex picks them from the
  same buffer, in ONE `awk` pass that now does the two counts as well (they
  were two `grep -c` over the same lines). `ts` is epoch seconds: logd and
  journalctl print local time without a zone, so the router's current offset
  is applied, while syslog-ng on Turris writes ISO 8601 with its own. `prog`
  is the program without its pid, null for a line with no date (its layout
  is unknown), and `count` how often the line repeats in the buffer.
- **Masked on the router.** A log line is the one thing in the report that can
  carry what the owner never meant to send, so before it leaves: MAC `<mac>`,
  IPv6 `<ipv6>`, IPv4 `<ipv4>`, e-mail `<email>`; names under a home domain
  (`.lan`, `.local`, `.home`, `.internal`, `.localdomain`, `.home.arpa`,
  `.fritz.box`), names that look like a device (`iphone`, `galaxy`,
  `desktop-`, ...) and the client name dnsmasq writes after a MAC `<host>`;
  hex runs of 12 or more (DUIDs, client ids) `<id>`. The mask runs BEFORE the
  cut to 200 characters, so a cut cannot leave half an address that no mask
  recognises. Every byte outside printable ASCII becomes `?`: the server
  refuses invalid UTF-8, and one stray byte must not cost the whole report.
  Lines are deduplicated on the masked text, so one failure against two
  addresses is one line with `count: 2`; the kernel's printk stamp
  (`[ 1234.567890]`) is dropped for the same reason, since `ts` already says
  when.
- **Cheap on a router in trouble.** The masks cost per character, and a
  failing router can fill all 500 lines with errors. So a line is cut to 256
  characters BEFORE masking - at a space, so no address is split, and marked
  `...` - the same text is masked once, and a cheap test skips every mask
  that cannot match. 500 error lines, each with its own address, take about
  30 ms of busybox `awk` on an arm64 laptop core; a log without errors costs
  nothing beyond the two counts.
- **Two switches keep the lines at home; the counts go either way.**
  `LOG_LINES_ENABLED=0` in `agent_openwrt.cfg` is the owner's, on the router.
  The monitor's setting is the server's: it answers every report with
  `"log_lines":true` or `"log_lines":false`, and the agent keeps a `false` as
  `agent_openwrt.loglines-off` next to the cfg. That is on flash on purpose:
  in `/var/run` a reboot would forget it and the first report would carry the
  lines again. A `true` removes the file; an answer without the key (an older
  server) changes nothing. `log_lines_state` names what applies - `on`,
  `off_monitor` or `off_router` - so a missing list is never read as "no
  errors".
- **Null, never an empty list**, when there is no readable log. `[]` means the
  log was read and holds no error line.

### What 0.1.7 stopped claiming, and what it now measures (OpenWrt)

Five fields of 0.1.6 were defaults dressed up as readings. They are null now,
and the app shows a dash:

- `dns_engine` and `dns_encryption` said "Dnsmasq" and "Nešifrované DNS
  (UDP/53)" for every router whose resolver the detection chain did not
  recognise - on Turris that is kresd behind a configuration the agent could
  not read, so the owner was told their DNS was in the clear when nobody had
  looked. Both are filled in only from evidence: a running process, a
  configuration file, or an established connection on port 853. Dnsmasq is now
  one more branch of that chain (`pidof dnsmasq`), not the fall-through.
- `dns_servers` no longer ends in "Výchozí poskytovatel (WAN)"; when neither
  netifd nor `/tmp/resolv.conf.auto` names a server, the agent does not know
  one.
- `wan_reconnect_count` started at 0, so a router reported "no reconnects"
  from its first minute although a reconnect is only VISIBLE as a drop of the
  WAN uptime between two runs. It is null until two samples have been
  compared; from then on 0 is a measured zero.
- `sqm_enabled` is null on a router with no SQM configuration at all (see the
  path section above), instead of "off".

Three signals were replaced or added:

- **`firewall_enabled` is the fw4 table.** fw4 loads one table, `inet fw4`,
  and loads it whole, so its presence in `nft list ruleset` (the dump the run
  already has) is the answer. The three signals 0.1.6 accepted all say
  something else: any non-empty ruleset is true on a router whose firewall
  never came up but which runs mwan3 or docker; `/etc/init.d/firewall enabled`
  says the service MAY start, and a syntax error in the rules leaves it
  enabled with the network wide open; and legacy `iptables -S` always prints
  policy lines. Without nft and without iptables the field stays null.
- **`dns_resolver_ok`** keeps the exit status of the probe that was already
  being run. Until now only its wall clock was read, so a resolver that
  refused the query in 3 ms was filed as the fastest DNS on the network.
  `dns_latency_ms` is null whenever the lookup failed - a refusal and a
  ten-second timeout are the same failure, and neither is a latency. (While
  fixing that: busybox has no `time` KEYWORD, `time` is the applet, and it
  writes its report to the stderr of the command it runs. The `2>&1` that sat
  on the lookup therefore threw the measurement away, and `dns_latency_ms` was
  null on every busybox router since the day it was written.)
- **`agent_time`** is the router's own clock, so the server can compute the
  distance to its own and warn about a router whose remote actions will start
  being refused.

Finally, the agent reports on itself (`agent_run_ms`, `agent_prev_total_ms`,
`runs_skipped_lock`, `runs_skipped_post`). The run length is measured from the
KERNEL uptime at both ends, never from the clock: ntpd steps the clock minutes
after boot on a router without an RTC, and a run would come out negative or
hours long. The payload is built before the POST, so a run cannot report its
own total - the EXIT trap writes it to `run.total` and the NEXT report carries
it as `agent_prev_total_ms`; the POST is usually what pushes a minute run past
its minute. A minute that produced no report cannot report itself either, so
each one appends a line to `skipped` (`l` = the previous run still held the
lock, `p` = the POST failed) and the next accepted report carries the counts
and drops exactly the lines it counted. That is how the server tells a router
that was switched off from an agent that cannot keep up.

### What the OpenWrt agent keeps on the router, and remote actions

The agent runs as root on a home gateway, so from 0.1.7 nothing it reads back
can be written by another local user:

- State the agent trusts lives in a private directory,
  `/var/run/status-agent-openwrt` (mode 0700, owned by root; on a system
  without `/var/run` it is `/tmp/status-agent-openwrt-private`, checked for
  owner and symlinks and replaced when somebody else made it first).
- The router identity cache is there (`identity.cache`, plain lines read with
  `read`, 24 h). Before 0.1.7 it was a file in `/tmp` that the agent `eval`'d.
- The last payload, for "what did the router send?", is
  `last-payload.json` in the same directory, mode 0600, with `agent_key`
  blanked. The old `/tmp/status-agent-openwrt-last-payload.json` is removed
  by the first run of the new version.
- The first run of a new agent version drops every cache an older version
  wrote (identity, package and service lists, HiLink, and from 0.1.7 the
  Wi-Fi, disk, SMART and WAN path caches), so a parser fix shows at the update
  and not a day later. Counters of work the owner consented to and results
  not sent yet are not caches and stay.

`--dry-run` prints the payload and sends nothing. Two variables exist for the
end-to-end tests and are honoured only together with `--dry-run`, so a cron
run can never be pointed at them: `STATUS_TEST_ROOT=<dir>` puts a fake `/sys`
and `/proc` in front of the disk, WAN port and per-core collectors, and
`STATUS_TEST_RESPONSE=<file>` stands in for the server's answer (see
`tests/README.md`).

Remote actions stay off unless `REMOTE_ACTIONS_ENABLED=1` is in
`agent_openwrt.cfg`. A correctly signed action must also pass these checks;
a refused one is reported to the dashboard as failed, with the reason:

- `ALLOWED_ACTIONS` is enforced. Without the line every action is allowed; a
  line with an empty value allows none. Example:
  `ALLOWED_ACTIONS=restart_wan,renew_dhcp`.
- A signed answer is single-use: its nonce is remembered for 60 s, the whole
  time its timestamp can be valid.
- `restart_service` takes a plain init script name (`[A-Za-z0-9_.-]`, no
  leading dot), never a path.

### Deployment (self-deploy to the dashboard hosting)

`.github/workflows/deploy-agents.yml` uploads the four agent files to
`public_html/status/` on every push that touches them, so self-updating routers
and servers get a fix as soon as it lands here — no `monitoring`-repo submodule
bump needed for the rollout (the bump remains as bookkeeping, and that repo's
deploy still copies the agents too; the two uploads keep separate FTP state
files and don't fight).

One-time setup: add the same `FTP_SERVER`, `FTP_USERNAME` and `FTP_PASSWORD`
secrets the `monitoring` repo uses under **Settings → Secrets and variables →
Actions**. The workflow fails loudly when they're missing instead of
pretending it deployed.

## Testing

`tests/` runs every agent for real, not just through a parser: `agent.sh` and
`agent.py` in a Debian container (two runs, so between-run deltas exist),
`agent_openwrt.sh` in busybox with canned `wg` / `mwan3` / `tc` / `uci` /
`logread` / `iwinfo` / `hostapd_cli` / `nft` / `ubus` output. Each harness asserts on the JSON
the agent prints with `--dry-run` - valid JSON, honest `null` on the first run,
parsers reading the right columns. Needs docker and python3:

```bash
bash tests/run_linux_e2e.sh
bash tests/run_openwrt_e2e.sh
```

Every agent also supports `--dry-run` (PowerShell: `-DryRun`): it collects
everything and prints the payload instead of sending it, no key needed - the
way to see what a new host will report before registering it.

#!/usr/bin/env python3
"""Asserts on the dry-run payloads produced by run_openwrt_e2e.sh.

Every expectation here matches the canned tool output in openwrt-stubs/bin;
a failing check means a parser in agent_openwrt.sh reads the wrong column,
fabricates a value, or emits invalid JSON."""
import collections
import glob
import ipaddress
import json
import os
import re
import sys

out = sys.argv[1]

def payload(name):
    """A run's payload. Every check below reads a parsed payload, so invalid
    JSON is the first failure and is reported as one FAIL line: a greedy
    `%%#*` split cuts the output at the '#' of an SSID and what is left is
    not JSON, and a traceback here would hide which run broke."""
    try:
        return json.load(open(f"{out}/{name}.json"))
    except (FileNotFoundError, ValueError) as exc:
        print(f"FAIL  payload: {name}.json is missing or is not valid JSON: {exc}")
        sys.exit(1)

d1 = payload("r1")
d = payload("r2")
d3 = payload("r3")  # no "wan" interface at all
d2b, d4, d5 = (payload(r) for r in ("r2b", "r4", "r5"))
# The payload runs' call logs: run-in-container.sh moves them to core/ before
# the scenario runs. Counting checks read core/ only; "never" checks read both.
def log_lines(name, core_only=False):
    lines = []
    for path in [f"{out}/core/{name}"] + ([] if core_only else [f"{out}/{name}"]):
        try:
            lines += open(path).read().splitlines()
        except FileNotFoundError:
            pass
    return lines
calls = log_lines("hilink_calls.log", core_only=True)
def hilink_calls(path):
    return sum(1 for c in calls if c.endswith(path))

try:
    log_size = int(open(f"{out}/logsize.txt").read().strip())
except (FileNotFoundError, ValueError):
    log_size = -1

# --- agent hardening runs (openwrt-stubs/runs-g28.sh) ---

def load(name):
    return json.load(open(f"{out}/{name}"))

def text(name):
    try:
        return open(f"{out}/{name}").read().strip()
    except FileNotFoundError:
        return None

def by_run(name):
    """'# tag' lines split a log into {tag: [lines]}."""
    runs, tag = {}, None
    for line in (text(name) or "").splitlines():
        if line.startswith("# "):
            tag = line[2:].split()[0]
            runs[tag] = []
        elif tag is not None:
            runs[tag].append(line)
    return runs

w17a, w17b, w17c = load("w17a.json"), load("w17b.json"), load("w17c.json")
w18, w18b = load("w18.json"), load("w18b.json")
# The kept copies may be missing or broken - that is a failed check, not a crash
# that hides every other result.
def load_kept(name):
    try:
        return load(name)
    except (FileNotFoundError, ValueError):
        return None
w18_kept, w18b_kept = load_kept("w18_last_payload.json"), load_kept("w18b_last_payload.json")
act_calls = by_run("action_calls.log")
act_results = by_run("action_results.log")
signed = by_run("openssl_calls.log")
resp1 = json.loads(open(f"{out}/w19_1.resp").read().split("\n", 1)[1])["pending_action"]

def refused(tag, reason):
    """One result, status failed, the reason named, and nothing was called."""
    res = act_results.get(tag, [])
    return len(res) == 1 and res[0].split("|")[1] == "failed" and reason in res[0] and act_calls.get(tag) == []

def uplink(item):
    return (item.get("uplink"), item.get("uplink_evidence"), item.get("iface"))


def by_stamp(p, ts):
    return next((i for i in p["speedtests"] if i["timestamp"] == ts), {})


def disk_names(payload):
    return {x["device"] for x in payload["disk_devices"]}
def disk_dev(payload, name):
    """The disk, or an empty stand-in: a payload that lost a disk has to turn
    its check red on its own line, not end the run with a traceback."""
    return next((x for x in payload["disk_devices"] if x["device"] == name), {})
def write_kbps(payload, name):
    """The write rate as a number, or None for "not measured" AND for a disk
    that is not in the payload at all - both are compared, never ordered."""
    v = disk_dev(payload, name).get("write_kbps")
    return v if isinstance(v, (int, float)) else None
seam_lines = [l.strip() for l in (text("seam_guard_all.txt") or "").splitlines()]
iwinfo_calls = log_lines("iwinfo_calls.log")
wpppoe = payload("wpppoe")
# One branch of the WAN walk per run (WAN 3.1.1): the port itself, a bridge
# over one port, a bridge over two, a lone ppp netdev, a dead DSA port.
wk1, wk2, wk3, wk4, wk5 = (payload(f"wwalk{n}") for n in range(1, 6))
# The speedtest hand-over and the path state, one scenario run each
# (openwrt-stubs/run-in-container.sh).
wack = [payload(f"wack{n}") for n in range(1, 7)]
wactive = payload("wactive")
wspeedfb, wspeed60, wspeedold = (payload(n) for n in ("wspeedfb", "wspeed60", "wspeedold"))
wpath = [payload(f"wpath{n}") for n in range(1, 9)]
wupl = {n: payload(f"wupl{n}") for n in (1, 3, 4, 6, 7)}
# The gap runs of INDEX 5.1 step 7: what "the firewall is up" is read from
# (G20), the DNS probe's exit status (G41), and the run's own clock together
# with the runs that never produced a report (G42).
wfw1, wfw2, wfw3 = (payload(f"wfw{n}") for n in (1, 2, 3))
wdns1, wdns3 = payload("wdns1"), payload("wdns3")
wrun2, wrun3, wrun4 = (payload(f"wrun{n}") for n in (2, 3, 4))
wrun5, wrun6, wrun7 = (payload(f"wrun{n}") for n in (5, 6, 7))

wport1, wport2, wport3 = (payload(f"wport{n}") for n in (1, 2, 3))

def lan_ports(p):
    """A run's wired switch ports, in the order the switch printed them. A run
    that reports no port section at all answers with an empty list here, which
    is why every check below also names what it expects of the section."""
    return ((p.get("lan_ports") or {}).get("ports")) or []

def lan_port(p, name):
    return next((q for q in lan_ports(p) if q.get("name") == name), {})

def stamps(p):
    """The timestamps a payload offers, in the order it offers them."""
    return [i["timestamp"] for i in (p.get("speedtests") or [])]

def path_of(p, key):
    wp = p.get("wan_path")
    return wp.get(key) if isinstance(wp, dict) else None

# Every payload file of every run, as text: what must never leave the router
# is searched for in all of them, not only in the one that was meant to hold it.
payload_text = "".join(
    open(f, errors="replace").read()
    for f in sorted(glob.glob(f"{out}/*.json")) if os.path.isfile(f))
uci_asked = collections.Counter(log_lines("uci_calls.log", core_only=True))
# The switch is read on EVERY run, so the six payload runs (r1, r2, r2b, r3,
# r4, r5) must show six dumps - one each. Two a run would be the hourly
# WAN-path block asking ubus for the same 27 kB again. Only five fdb reads:
# r3 is the access point whose ubus has no netifd at all, and a run that
# never saw a switch has no bridge to ask about either.
dev_dumps = sum(1 for c in log_lines("ubus_calls.log", core_only=True)
                if c == "call network.device status")
fdb_reads = len(log_lines("bridge_calls.log", core_only=True))

# No address that belongs to somebody may live in this suite: neither in a
# fixture nor in a payload the fixtures produce. Allowed are the documentation
# ranges (RFC 5737 192.0.2/198.51.100/203.0.113, RFC 3849 2001:db8::/32), the
# private ones (RFC 1918, ULA fc00::/7), loopback and link-local - exactly what
# Python's is_private/is_loopback/is_link_local cover.
ADDR_RE = re.compile(
    r"\b(?:\d{1,3}\.){3}\d{1,3}\b"
    r"|\b[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){7}\b"
    r"|(?<![0-9a-fA-F:])[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{0,4}){0,6}::"
    r"[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{1,4}){0,6}(?![0-9a-fA-F:])")
def public_addrs(s):
    bad = set()
    for lit in ADDR_RE.findall(s):
        # `a[::2]` in a test script is a slice, not an address; a real one
        # always carries a group of at least two hex digits.
        if ":" in lit and not any(len(g) >= 2 for g in lit.split(":")):
            continue
        try:
            ip = ipaddress.ip_address(lit)
        except ValueError:
            continue
        if not (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_unspecified):
            bad.add(lit)
    return bad
fixture_addrs = set()
for _dir, _subdirs, _names in os.walk(os.path.dirname(os.path.abspath(__file__))):
    _subdirs[:] = [x for x in _subdirs if x != "__pycache__"]
    for _n in sorted(_names):
        fixture_addrs |= public_addrs(open(os.path.join(_dir, _n), errors="replace").read())
def wan_keys(p, *keys):
    return [p.get(k, "MISSING") for k in keys]
# WAN e2e #14: everything 0.1.7 adds to the minute report at the top level.
# The softnet keys are LATER (X3), `cpu_core_max_system_pct` has no consumer
# (X9), and the probe's own state and items are wave 2.
WAN_NEW_KEYS = (
    "cpu_cores", "cpu_core_max_pct", "cpu_core_max_index", "cpu_core_max_softirq_pct",
    "wan_link_dev", "wan_link_mbit", "wan_carrier_down_count", "wan_rx_mbps", "wan_tx_mbps",
    "wan_rx_errors", "wan_tx_errors", "wan_rx_dropped", "wan_tx_dropped",
    "conntrack_insert_failed", "conntrack_drop", "conntrack_early_drop",
    "speedtest_active", "agent_time", "dns_resolver_ok", "agent_run_ms",
    "agent_prev_total_ms", "runs_skipped_lock", "runs_skipped_post", "wan_path")
selftest = (text("stub_selftest.txt") or "").splitlines()

wg = d["wireguard_peers"]
def by_radio(payload):
    """The run's radios by name. A radio that fell out of the payload - the awk
    died, the radio list is empty - answers every field with None, so its own
    checks fail on their own lines instead of ending the run with a KeyError
    that hides all the others."""
    absent = collections.defaultdict(lambda: None)
    m = collections.defaultdict(lambda: absent)
    for r in payload["wifi_radios"]:
        m[r["radio"]] = collections.defaultdict(lambda: None, r)
    return m
radios, radios3, radios1, radios2b = (by_radio(x) for x in (d, d3, d1, d2b))
def gen_sum(r):
    """Associated stations the generation counter saw."""
    g = r["clients_gen"] or {}
    return sum(g.get(k) or 0 for k in ("legacy", "wifi4", "wifi5", "wifi6", "wifi7"))

def by_disk(payload):
    """The run's physical disks by name. A disk that fell out of the payload -
    the awk died, storage_disks came back null - answers every field with None
    (and an all-None `smart`), so its own checks fail on their own lines
    instead of ending the run with a KeyError that hides all the others."""
    absent = collections.defaultdict(lambda: None)
    absent["smart"] = collections.defaultdict(lambda: None)
    m = collections.defaultdict(lambda: absent)
    for x in payload["storage_disks"] or []:
        row = collections.defaultdict(lambda: None, x)
        row["smart"] = collections.defaultdict(lambda: None, x.get("smart") or {})
        m[x["name"]] = row
    return m
def disk_list(payload):
    return [x["name"] for x in payload["storage_disks"] or []]
def smart_values(run, name):
    """Everything under `smart` except the state itself."""
    return {k: v for k, v in run[name]["smart"].items() if k != "state"}
sd1, sd, sd2b, sd3, sd4, sd5 = (by_disk(x) for x in (d1, d, d2b, d3, d4, d5))
sdw = by_disk(payload("wsmart2"))
wlock = payload("wlock")
smartctl_calls = log_lines("smartctl_calls.log")
smartctl_core = log_lines("smartctl_calls.log", core_only=True)
def smartctl_devs(lines):
    return [c.split()[-1] for c in lines]
def cache_line(name, dev):
    """One disk's line of a kept smart.cache, split on |; [] when it has none."""
    for line in (text(name) or "").splitlines():
        f = line.split("|")
        if len(f) > 2 and f[1] == dev:
            return f
    return []
# Nothing that identifies a drive may reach a payload or a state file. The
# decoys are planted in the fake sysfs (wwid, vpd_pg80, serial, cid) and in
# smartctl's answer whenever -q noserial is missing from argv.
leaked = sorted(
    os.path.relpath(f, out) for f in glob.glob(f"{out}/*") + glob.glob(f"{out}/core/*")
    if os.path.isfile(f) and re.search("DECOYSERIAL|SERIALLEAK|4276994270", open(f, errors="replace").read()))
checks = {
    "wireguard: the interface line is skipped, two peers remain": len(wg) == 2,
    "wireguard: public_key is the peer's key, not the private key": wg[0]["public_key"].startswith("PEERONEpubke"),
    "wireguard: handshake/rx/tx come from the right columns": (wg[0]["latest_handshake"], wg[0]["rx_bytes"], wg[0]["tx_bytes"]) == (1725000000, 12345, 67890),
    "wireguard: IPv6 endpoint without port and brackets": wg[1]["endpoint"] == "2001:db8::1",
    "mwan3: active gateway is the online interface": d["mwan3_active_gw"] == "wan",
    "mwan3: interface list online/offline": [(p["interface"], p["status"]) for p in d["mwan3_policies"]] == [("wan", "online"), ("wwan", "offline")],
    "sqm: dropped read after the word, ecn not measured": wpath[0]["sqm_dropped"] == 12 and wpath[0]["sqm_ecn"] is None,
    "service restarts counted from one logread": d["service_restarts"] == {"dnsmasq": 2, "uhttpd": 1},
    "log errors counted": d["log_errors_24h"] == 2,
    "wifi: enabled radio has channel, clients, power, noise": radios["wlan0"]["channel"] == 6 and radios["wlan0"]["clients"] == 3 and radios["wlan0"]["tx_power"] == 20 and radios["wlan0"]["noise"] == -95,
    "wifi: an SSID with a quote, a backslash and a # round-trips exactly": radios["wlan0"]["ssid"] == 'Kafe "U Pepy" #1 \\o/',
    "omnia: band comes from the frequency (5180 -> 5GHz, 5955 -> 6GHz, 2437 and 2432 -> 2.4GHz)": [radios[r]["band"] for r in ("phy0-ap0", "wlan6", "wlan0", "phy3-ap0")] == ["5GHz", "6GHz", "2.4GHz", "2.4GHz"],
    "omnia: both radios of the owner's router are reported - phy0-ap0 on channel 36 with 4 clients, phy3-ap0 on channel 5 with 6": (radios["phy0-ap0"]["channel"], radios["phy0-ap0"]["clients"], radios["phy0-ap0"]["tx_power"], radios["phy0-ap0"]["noise"]) == (36, 4, 23, -92) and (radios["phy3-ap0"]["channel"], radios["phy3-ap0"]["clients"]) == (5, 6),
    "omnia: a driver that reports no noise (phy3-ap0) gives null, not 0 and not another radio's value": radios["phy3-ap0"]["noise"] is None and radios["phy3-ap0"]["tx_power"] == 20,
    "wifi: disabled radio reports null, not channel 0 at 0 dBm": radios["wlan1"]["channel"] is None and radios["wlan1"]["tx_power"] is None and radios["wlan1"]["noise"] is None and radios["wlan1"]["ssid"] is None and radios["wlan1"]["clients"] == 0,
    # wlan0 3 + wlan1 0 + phy0-ap0 4 + wlan7 0 + phy3-ap0 6 + wlan6 1 (its
    # assoclist says "No information available", so the count comes from ubus)
    "wifi_clients_count is the sum over radios": d["wifi_clients_count"] == 14,
    "wifi: op classes stop at the 0x00/0x82 delimiter - the decoy tail 87 85 does not make a client 6 GHz capable": radios["wlan0"]["clients_6ghz_capable"] == 1 and radios["wlan0"]["clients_caps_known"] == 3,
    "wifi 6e: a radio hostapd does not answer for is unknown, not zero": radios["wlan1"]["clients_6ghz_capable"] is None and radios["wlan1"]["clients_caps_known"] is None,
    "wifi 6e: without hostapd_cli support is unknown and the client count stays": radios3["wlan0"]["clients_6ghz_capable"] is None and radios3["wlan0"]["clients_caps_known"] is None and radios3["wlan0"]["clients"] == 3,
    # --- Wi-Fi collector (CORE 2.2, 2.6; e2e #2-#17, #20, #39, #42, #43) ---
    "wifi: a disabled radio has band null, not a guessed 2.4GHz": (radios["wlan1"]["band"], radios["wlan1"]["frequency_mhz"], radios["wlan1"]["htmode"], radios["wlan1"]["encryption"]) == (None, None, None, None),
    "wifi: no hwmodes key and no bssid or mac address anywhere in the payload": not any(k in json.dumps(d) for k in ('"hwmodes"', '"bssid"', '"access_point"')) and not re.search(r'([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}', json.dumps(d["wifi_radios"])),
    "omnia: HE80 on channel 36, phy0, mode ap, tx 23, noise -92": [radios["phy0-ap0"][k] for k in ("htmode", "phy", "mode", "tx_power", "noise", "channel")] == ["HE80", "phy0", "ap", 23, -92, 36],
    "omnia: phy3-ap0 runs HT20 - the generation and width the app shows (Wi-Fi 4, 20 MHz) are read from that one field": radios["phy3-ap0"]["htmode"] == "HT20" and radios["phy3-ap0"]["htmodes_supported"] == ["HT20", "HT40"],
    "omnia: encryption mixed WPA2/WPA3 -> wpa2_wpa3, not enterprise; wlan0 -> wpa2; wlan6 -> wpa3": [radios[r]["encryption"] for r in ("phy0-ap0", "phy3-ap0", "wlan0", "wlan6")] == ["wpa2_wpa3", "wpa2_wpa3", "wpa2", "wpa3"] and radios["phy0-ap0"]["encryption_enterprise"] is False,
    "wifi: mixed WPA/WPA2 (TKIP) -> wpa_wpa2, never wpa2 - the version-1 test runs before the WPA2 one": radios["wlan7"]["encryption"] == "wpa_wpa2",
    "omnia: station statistics come from assoclist (median -54, min -75, weakest SNR 17, 1 weak, mean TX 736.8)": [radios["phy0-ap0"][k] for k in ("signal_median", "signal_min", "snr_min", "clients_weak", "bitrate_tx_avg_mbps")] == [-54, -75, 17, 1, 736.8],
    "wifi: the mean TX rate is the stations' one, not the AP-side Bit Rate (wlan0 72.0, not 130.0)": radios["wlan0"]["bitrate_tx_avg_mbps"] == 72.0,
    "wifi: a station with an unknown signal is left out of the statistics, not counted as 0": (radios["wlan0"]["signal_median"], radios["wlan0"]["signal_min"], radios["wlan0"]["clients"]) == (-53, -60, 3),
    "wifi: an SNR printed next to an unknown noise is not a measurement (wlan0: snr_min 35, not -45)": radios["wlan0"]["snr_min"] == 35,
    "omnia: a radio without noise reports no SNR either, but still ranks its stations (phy3-ap0)": radios["phy3-ap0"]["snr_min"] is None and (radios["phy3-ap0"]["signal_median"], radios["phy3-ap0"]["signal_min"]) == (-63, -71),
    "omnia: generations 2x Wi-Fi 6, 1x Wi-Fi 5, 1x Wi-Fi 4; the weakest client is Wi-Fi 4": radios["phy0-ap0"]["clients_gen"] == {"source": "hostapd_cli", "legacy": 0, "wifi4": 1, "wifi5": 1, "wifi6": 2, "wifi7": 0} and radios["phy0-ap0"]["weakest_gen"] == 4,
    "omnia: 6 GHz capable 2 of 4 KNOWN - on an HE AP a station without [HE] is known-not-capable": [radios["phy0-ap0"][k] for k in ("clients_6ghz_capable", "clients_caps_known", "clients_opclass_known")] == [2, 4, 2],
    "wifi: on a non-HE AP a station without [HE] is NOT known without its op-class list (phy3-ap0: 0 of 6)": [radios["phy3-ap0"][k] for k in ("clients_caps_known", "clients_6ghz_capable", "clients_opclass_known")] == [0, 0, 0],
    "wifi: an unassociated station ([AUTH] only) is not counted": gen_sum(radios["wlan0"]) == 3 and radios["wlan0"]["clients_caps_known"] == 3,
    "omnia: AKM - 4 of 4 stations WPA3, 0 WPA2; wlan0 2 WPA2 and 1 WPA3": [radios["phy0-ap0"][k] for k in ("clients_akm_known", "clients_wpa3", "clients_wpa2", "clients_8021x")] == [4, 4, 0, 0] and [radios["wlan0"][k] for k in ("clients_akm_known", "clients_wpa2", "clients_wpa3")] == [3, 2, 1],
    "omnia: with no AKM line SAE is read from [MFP] - 3 of phy3-ap0's 6 stations are WPA2, the other 3 stay unknown": [radios["phy3-ap0"][k] for k in ("clients_akm_known", "clients_wpa2", "clients_wpa3")] == [3, 3, 0],
    "wifi: 5 GHz capable is reported on the 2.4 GHz radio only (wlan0 3; 5 and 6 GHz radios null)": [radios[r]["clients_5ghz_capable"] for r in ("wlan0", "phy0-ap0", "wlan7", "wlan6")] == [3, None, None, None],
    "omnia: stations that sent no op-class list are not 5 GHz capable and not counted as known (phy3-ap0: 0 of 0)": (radios["phy3-ap0"]["clients_5ghz_capable"], radios["phy3-ap0"]["clients_opclass_known"]) == (0, 0),
    "omnia: busy_pct is null/warming_up on the first run and 3.5 on the second, busy_other 1.2 (the decoy in-use block on 2437 MHz is ignored)": (radios1["phy0-ap0"]["busy_pct"], radios1["phy0-ap0"]["busy_state"]) == (None, "warming_up") and [radios["phy0-ap0"][k] for k in ("busy_pct", "busy_other_pct", "busy_state")] == [3.5, 1.2, "measured"],
    "wifi: the channel load is the last minute, not the lifetime average (wlan7: 10.0 % busy and 5.0 % foreign from the deltas, while its counters since boot say 74.0 % and 12.4 %)": (radios["wlan7"]["busy_pct"], radios["wlan7"]["busy_other_pct"], radios["wlan7"]["busy_state"]) == (10.0, 5.0, "measured"),
    "wifi: an implausible survey delta (wlan0: +60,000 ms of channel time in about 11 s) stays null and warming_up": (radios["wlan0"]["busy_pct"], radios["wlan0"]["busy_state"]) == (None, "warming_up"),
    "omnia: a driver with no survey data at all is unsupported on EVERY run, never 0 % (phy3-ap0)": all((r["phy3-ap0"]["busy_pct"], r["phy3-ap0"]["busy_state"]) == (None, "unsupported") for r in (radios1, radios, radios2b)),
    "wifi: without iw busy is null with busy_state not_installed; never 0": (radios3["phy0-ap0"]["busy_pct"], radios3["phy0-ap0"]["busy_state"]) == (None, "not_installed"),
    "wifi: without hostapd_cli generations come from ubus, wifi7 is null, AKM and op-class counts are null, nested capabilities.vht is not a flag": radios3["phy0-ap0"]["clients_gen"] == {"source": "ubus", "legacy": 0, "wifi4": 1, "wifi5": 1, "wifi6": 2, "wifi7": None} and [radios3["phy0-ap0"][k] for k in ("clients_akm_known", "clients_opclass_known", "clients_wpa2")] == [None, None, None],
    "wifi: an AP with nobody connected is a measured zero - of the six payload runs only r3, which has no hostapd_cli, asks ubus about wlan7": [radios["wlan7"][k] for k in ("clients", "clients_weak", "clients_akm_known", "clients_opclass_known", "clients_caps_known")] == [0, 0, 0, 0, 0] and radios["wlan7"]["clients_gen"] == {"source": "hostapd_cli", "legacy": 0, "wifi4": 0, "wifi5": 0, "wifi6": 0, "wifi7": 0} and radios["wlan7"]["signal_median"] is None and sum("hostapd.wlan7" in c for c in log_lines("ubus_calls.log", core_only=True)) == 1,
    "wifi: a radio whose assoclist says 'No information available' takes the count from hostapd (wlan6: 1 through ubus)": radios["wlan6"]["clients"] == 1 and radios["wlan6"]["clients_gen"]["source"] == "ubus" and radios["wlan6"]["clients_weak"] is None,
    "wifi: the card facts come from the daily cache - one htmodelist and one freqlist call per radio across all runs": sorted(c for c in log_lines("iwinfo_calls.log", core_only=True) if c.endswith(("htmodelist", "freqlist"))) == sorted(f"{r} {c}" for r in ("wlan0", "wlan1", "phy0-ap0", "wlan6", "wlan7", "phy3-ap0") for c in ("htmodelist", "freqlist")),
    "wifi: htmodes_supported and phy_has_6ghz come from that cache - only the 6 GHz radio has a 6 GHz band": [radios[r]["phy_has_6ghz"] for r in ("wlan6", "phy0-ap0", "wlan0")] == [True, False, False] and radios["phy0-ap0"]["htmodes_supported"][-1] == "HE160",
    "payload budget: wifi_radios stays under 5500 B for six radios": len(json.dumps(d["wifi_radios"], separators=(",", ":"))) <= 5500,
    "firewall: accept/drop/reject sums and enabled from one ruleset": (d["fw_accepted"], d["fw_dropped"], d["fw_rejected"], d["firewall_enabled"]) == (200, 5, 3, True),
    "firewall: one terse nft listing per payload run (-t leaves the set elements out) and never a second": log_lines("nft_calls.log", core_only=True) == ["-t list ruleset"] * 6,
    "firewall: an nft without -t is asked again without it and answers the same (wdns1); an empty kernel is asked twice (wfw2)": collections.Counter(log_lines("nft_calls.log"))["list ruleset"] == 2 and (wdns1["fw_accepted"], wdns1["fw_dropped"], wdns1["fw_rejected"], wdns1["firewall_enabled"]) == (200, 5, 3, True) and path_of(wdns1, "flowtable_active") is True,
    "netifd: the interface dump is loaded into jshn once per run - five payload runs have a dump (r3 has none), none loads it twice": sorted(collections.Counter(log_lines("jshn_calls.log", core_only=True)).values()) == [1] * 5,
    "top: both rankings list the container's processes, never [] - the agent itself and its sampler are left out": all(isinstance(p[k], list) and len(p[k]) >= 1 and all(set(x) == {"name", "cpu", "ram_mb"} and isinstance(x["name"], str) and x["name"] for x in p[k]) for p in (d1, d) for k in ("top_cpu_processes", "top_ram_processes")),
    "wan: interface up and the bound echo answered": d["wan_up"] is True and d["wan_internet"] is True,
    "dhcp: no lease file is unknown, reservations counted": d["dhcp_leases_count"] is None and d["dhcp_reservations_count"] == 3,
    "cpu: null on the first run, a number on the second": d1["cpu"] is None and isinstance(d["cpu"], (int, float)),
    "oom_kills is a number": isinstance(d["oom_kills"], int),
    "no value is the string 'null'": all(v != "null" for v in d.values()),
    "no wan interface: wan_up and wan_internet are null, not false": d3["wan_up"] is None and d3["wan_internet"] is None and d3["wan_proto"] is None,
    "wan: address and gateway from the one interface dump": d["wan_ipv4"] == "203.0.113.10" and d["wan_gateway"] == "203.0.113.1" and d["wan_proto"] == "dhcp",
    "lan: subnet from the same dump": d["lan_subnet"] == "192.168.1.1/24",
    "lte: interface found by name, address and uptime read": d["lte_up"] is True and d["lte_ipv4"] == "192.168.8.100" and d["lte_uptime"] == 700,
    "hilink: registration and SIM verdict": d["lte_connected"] is True and d["lte_sim_state"] == "ready" and d["lte_conn_code"] == 901 and d["lte_service_code"] == 2 and d["lte_sim_status_code"] == 1 and d["lte_sim_pin_left"] == 3,
    "hilink: signal, band, PLMN, operator": d["lte_rsrp"] == -85 and d["lte_band"] == "B20" and d["lte_plmn"] == "23001" and d["lte_carrier"] == "T-Mobile CZ",
    # r1, r2, r2b, r4, r5; r3 has no interface at all and so no modem to ask
    "hilink: registration asked every run": hilink_calls("/api/monitoring/status") == 5,
    "hilink: SIM state and operator asked once, then served from the cache": hilink_calls("/api/pin/status") == 1 and hilink_calls("/api/net/current-plmn") == 1,
    "no interfaces at all: LTE stays unknown": d3["lte_up"] is None and d3["lte_connected"] is None,
    "link roles: the WAN device is reported, the LTE rate is measured on the second run": d["wan_l3_device"] == "eth0" and d1["net_lte"] is None and isinstance(d["net_lte"], (int, float)),
    "no interfaces at all: no WAN device, no LTE rate": d3["wan_l3_device"] is None and d3["net_lte"] is None,
    "the log is trimmed on a router that has no stat applet": 0 < log_size <= 40000,
    "version reported": d.get("version") == "0.1.11",
    # --- storage and SMART (CORE 2.3, 2.7; CORE e2e #22-#39, #44, #45) ---
    # CORE e2e #22
    "omnia: storage_disks has sda and no loop*, mtdblock*, zram* - and no mmcblk0; emmc is null":
        disk_list(d) == ["nvme0n1", "sda", "sdb", "sdc", "sdd"] and sd["sda"]["emmc"] is None,
    # CORE e2e #23
    "omnia: sda is sata on ata1, 120034123776 B, not rotational, sysfs model KINGSTON SUV500M":
        [sd["sda"][k] for k in ("transport", "port", "size_bytes", "rotational", "removable", "model")]
        == ["sata", "ata1", 120034123776, False, False, "KINGSTON SUV500M"]
        and [sd["sdb"]["transport"], sd["sdb"]["port"], sd["sdb"]["rotational"], sd["sdb"]["model"]] == ["usb", "usb:4-1", True, "WD Elements 25A2"]
        and [sd["nvme0n1"]["transport"], sd["nvme0n1"]["port"]] == ["nvme", "nvme0"]
        and sd["sdc"]["removable"] is True,
    # CORE e2e #24
    "storage: partitions join df by device, shortest mount wins, a mount with a space, a # and quotes survives exactly":
        sd["sda"]["partitions"] == [{"name": "sda1", "size_bytes": 120033075200, "mount": "/", "fstype": "btrfs", "used_pct": 19}]
        and sd["sdb"]["partitions"] == [{"name": "sdb1", "size_bytes": 1000203837440, "mount": '/mnt/usb #1 "disk"', "fstype": "ext4", "used_pct": 53}]
        and sd["nvme0n1"]["partitions"] == [{"name": "nvme0n1p1", "size_bytes": 256059465728, "mount": None, "fstype": None, "used_pct": None}],
    # CORE e2e #25
    "smart: first run is pending with every value null; second run is ok":
        sd1["sda"]["smart"]["state"] == "pending" and all(v is None for v in smart_values(sd1, "sda").values())
        and sd["sda"]["smart"]["state"] == "ok" and sd["sda"]["smart"]["checked_at"] > 0,
    # CORE e2e #26
    "omnia: SMART values - passed, 67 C, 24750 h, 230 cycles, 227 unclean, realloc 0, pending 0, reported 0, crc 0, 183 = 3, error log 0, self-tests 0, smart model KINGSTON SUV500MS120G":
        [sd["sda"]["smart"][k] for k in ("passed", "in_drivedb", "protocol", "model", "rotation_rpm", "temperature_c",
                                         "power_on_hours", "power_cycles", "unsafe_shutdowns", "reallocated_sectors",
                                         "pending_sectors", "reported_uncorrect", "crc_errors", "runtime_bad_blocks",
                                         "error_log_count", "selftest_count", "exit_bits")]
        == [True, True, "ATA", "KINGSTON SUV500MS120G", 0, 67, 24750, 230, 227, 0, 0, 0, 0, 3, 0, 0, 0],
    # CORE e2e #27
    "omnia: attribute 198 is absent, so offline_uncorrectable is null, not 0":
        sd["sda"]["smart"]["offline_uncorrectable"] is None and sd["sda"]["smart"]["reallocated_sectors"] == 0,
    # CORE e2e #28
    "omnia: temperature is temperature.current (67), never the packed raw 194 (292058955843)":
        sd["sda"]["smart"]["temperature_c"] == 67,
    # CORE e2e #29
    "omnia: 241 Host_Writes_GiB 420 -> 450971566080 B, source attr241; wear 0 from attr231":
        [sd["sda"]["smart"][k] for k in ("written_bytes", "written_source", "wear_pct", "wear_source")]
        == [450971566080, "attr241", 0, "attr231"],
    # CORE e2e #30
    "smart: without the drive database (sdd) 241/231/183/174 are NOT interpreted - wear, unsafe shutdowns and bad blocks null; written comes from devstat only":
        sd["sdd"]["smart"]["in_drivedb"] is False
        and [sd["sdd"]["smart"][k] for k in ("wear_pct", "wear_source", "unsafe_shutdowns", "runtime_bad_blocks")] == [None, None, None, None]
        and [sd["sdd"]["smart"][k] for k in ("written_bytes", "written_source")] == [450971566080, "devstat"]
        and sd["sdd"]["smart"]["temperature_c"] == 67,
    # CORE e2e #31
    "smart: every smartctl call carries --json=g, -q noserial and (non-NVMe) -n standby,3":
        len(smartctl_calls) > 0 and all("--json=g" in c and "-q noserial" in c for c in smartctl_calls)
        and all(("-n standby,3" in c) != ("/dev/nvme" in c) for c in smartctl_calls),
    # CORE e2e #32
    "smart: at most one call per disk across all runs (hourly cache)":
        sorted(smartctl_devs(smartctl_core)) == ["/dev/nvme0n1", "/dev/sda", "/dev/sdb", "/dev/sdc", "/dev/sdd", "/dev/sde"],
    # CORE e2e #33
    "smart: an idle spinning disk is not touched (r1: idle_skipped, no /dev/sdb in the call log); once active it is probed and r2b reports standby with null values and checked_at null":
        sd1["sdb"]["smart"]["state"] == "idle_skipped" and "sdb" not in (text("r1_smart.cache") or "")
        and all(v is None for v in smart_values(sd1, "sdb").values())
        and sd2b["sdb"]["smart"]["state"] == "standby" and all(v is None for v in smart_values(sd2b, "sdb").values()),
    # A disk that falls asleep between two readings (CORE 2.7.4: with `standby`
    # the values are the PREVIOUS reading and checked_at is that reading's time)
    "smart: a disk that goes to standby keeps its last real reading and ITS time - never a row of nulls":
        cache_line("wsmart_smart.cache", "sdb")[4:7] == [text("wsmart_ts.txt"), "3", "standby"]
        and sdw["sdb"]["smart"]["state"] == "standby"
        and [sdw["sdb"]["smart"][k] for k in ("temperature_c", "power_on_hours", "power_cycles", "rotation_rpm")] == [38, 9000, 120, 5400]
        and str(sdw["sdb"]["smart"]["checked_at"]) == text("wsmart_ts.txt"),
    # CORE 2.7.4: "A live PID in the lock means: spawn nothing."
    "smart: while a refresh is running nothing new is spawned - four disks are due and unread, not one smartctl is called, the lock is left alone":
        text("wlock_before.txt") == text("wlock_after.txt") and (text("wlock_before.txt") or "") != ""
        and [x["smart"]["state"] for x in wlock["storage_disks"]] == ["pending", "pending", "idle_skipped", "pending", "pending"]
        and text("wlock_lock.txt") == "yes"
        and isinstance(wlock["agent_tools"]["smart_probe_running_s"], int)
        and 0 <= wlock["agent_tools"]["smart_probe_running_s"] < 900,
    # CORE e2e #34
    "smart: Unknown USB bridge -> unsupported; NVMe critical warning -> failing":
        sd["sdc"]["smart"]["state"] == "unsupported" and all(v is None for v in smart_values(sd, "sdc").values())
        and sd["nvme0n1"]["smart"]["state"] == "failing"
        and [sd["nvme0n1"]["smart"][k] for k in ("critical_warning", "media_errors", "available_spare_pct", "exit_bits", "passed",
                                                 "wear_pct", "wear_source", "written_bytes", "written_source", "protocol")]
        == [4, 2, 100, 8, False, 3, "nvme", 614400000000, "nvme", "NVMe"],
    # CORE e2e #35
    "smart: without smartctl every value is null and state is not_installed, although smart.cache still exists":
        disk_list(d3) == disk_list(d)
        and all(sd3[n]["smart"]["state"] == "not_installed" and all(v is None for v in smart_values(sd3, n).values()) for n in disk_list(d3))
        and "sda" in (text("r3_smart.cache") or ""),
    # CORE e2e #36
    "privacy: DECOYSERIAL, 4276994270 and SERIALLEAK appear in no payload and no cache file":
        leaked == [],
    # INDEX section 4, NEW: the owner's own addresses are what the masking of
    # the fixtures is about, and a resolver somebody really runs is an address
    # too. Both halves are checked: what the suite carries in, and what the
    # agent prints out of it.
    "privacy: every address in the fixtures and in the payloads they produce is a documentation or private one":
        fixture_addrs == set() and public_addrs(payload_text) == set(),
    # CORE e2e #37
    "emmc: life_time 0x02 0x01 -> life_a 2, life_b 1, pre_eol 1, state not_applicable; boot and rpmb partitions are not disks":
        sd4["mmcblk0"]["emmc"] == {"life_a": 2, "life_b": 1, "pre_eol": 1}
        and sd4["mmcblk0"]["transport"] == "emmc" and sd4["mmcblk0"]["port"] == "mmc0"
        and sd4["mmcblk0"]["smart"]["state"] == "not_applicable" and all(v is None for v in smart_values(sd4, "mmcblk0").values())
        and disk_list(d4) == ["mmcblk0", "nvme0n1", "sda", "sdb", "sdc", "sdd", "sde"]
        and [p["name"] for p in sd4["mmcblk0"]["partitions"]] == ["mmcblk0p1", "mmcblk0p2"]
        and "/dev/mmcblk0" not in smartctl_devs(smartctl_calls),
    # CORE e2e #38
    "agent_tools: flags typed; smart_probe_running_s null when idle":
        d["agent_tools"] == {"smartctl": True, "smart_drivedb": False, "hostapd_cli": True, "iw": True, "pkg_manager": None,
                             "smart_probe_age_s": d["agent_tools"]["smart_probe_age_s"], "smart_probe_running_s": None,
                             "librespeed_cli": False, "ethtool": False, "tc": True}
        and isinstance(d["agent_tools"]["smart_probe_age_s"], int)
        and d1["agent_tools"]["smart_probe_age_s"] is None
        and [d3["agent_tools"][k] for k in ("smartctl", "hostapd_cli", "iw")] == [False, False, False],
    # CORE e2e #39
    "payload budget: storage_disks <= 5000 B for 5 disks, wifi_radios <= 4500 B for 5 radios":
        len(json.dumps(d["storage_disks"], separators=(",", ":"))) <= 5000 and len(disk_list(d)) == 5
        and len(json.dumps(d["wifi_radios"], separators=(",", ":"))) <= 4500,
    # CORE e2e #44
    "smart: a smartctl that ignores TERM is killed with KILL - sde is error with rc 124, no smartctl process is left, smart.lock is gone":
        sd4["sde"]["smart"]["state"] == "pending"
        and cache_line("r4_smart.cache", "sde")[4:7] == ["", "124", "error"]
        and text("r4_procs.txt") == "0" and text("r4_lock.txt") == "no",
    # CORE e2e #45
    "smart: a lock held by a live PID blocks every probe - r5 adds no line to smartctl_calls.log, sda is stuck with its previous values, agent_tools.smart_probe_running_s >= 1000, smart.lock still exists after the run":
        sd5["sda"]["smart"]["state"] == "stuck" and sd5["sda"]["smart"]["temperature_c"] == 67
        and sd5["sda"]["smart"]["checked_at"] == sd["sda"]["smart"]["checked_at"]
        and (d5["agent_tools"]["smart_probe_running_s"] or 0) >= 1000
        and text("r5_lock.txt") == "yes"
        and smartctl_devs(smartctl_core).count("/dev/sda") == 1,
    # The dry-run seam and the harness itself (CORE 2.7.1, 6.1; release contract X18-X20)
    "seam: disk_devices is read from the fake root - the Omnia's disks, none of the CI runner's": disk_names(d) == {"sda", "sdb", "sdc", "sdd", "nvme0n1", "mtdblock0"} and disk_names(d4) == disk_names(d) | {"mmcblk0", "sde"},
    "seam: the disks that moved between r1 and r2 have a write rate, the idle ones a measured 0": [write_kbps(d, "sdc"), write_kbps(d1, "sda")] == [0, None] and "sda" in disk_names(d1) and 0 < (write_kbps(d, "sda") or 0) < 300 and 0 < (write_kbps(d, "sdb") or 0) < 10,
    "seam: every test variable is read on one line, and that line asks for --dry-run": seam_lines == [
        '[ "$DRY_RUN" = "1" ] && [ -n "$STATUS_TEST_RESPONSE" ] && BK_TEST_RESPONSE="$STATUS_TEST_RESPONSE"',
        'BK_ROOT=""',
        '[ "$DRY_RUN" = "1" ] && [ -n "$STATUS_TEST_ROOT" ] && BK_ROOT="$STATUS_TEST_ROOT"',
        '[ "$DRY_RUN" = "1" ] && [ -n "$STATUS_TEST_TTY" ] && BK_TEST_TTY="$STATUS_TEST_TTY"'],
    "wifi: every iwinfo call carries exactly one command": len(iwinfo_calls) > 0 and all(len(c.split()) <= 2 for c in iwinfo_calls),
    "wifi: iwinfo was never asked to scan": log_lines("iwinfo_scan.log") == [],
    "harness: the stubs refuse and answer like the real tools (openwrt-stubs/selftest.sh, 74 checks)": len(selftest) == 74 and all(l.startswith("ok ") for l in selftest),
    "harness: all six payload runs produced a payload of this version": all(x.get("version") == d["version"] for x in (d1, d2b, d3, d4, d5)),
    "wan: PPPoE over a VLAN (the owner's line) - the l3 device is the ppp netdev": (wpppoe["wan_proto"], wpppoe["wan_l3_device"], wpppoe["wan_up"]) == ("pppoe", "pppoe-wan", True),
    # --- W-A2 the WAN device walk (WAN 3.1.1; WAN e2e #5) ---
    "wan: a port that answers for itself is the port, and the rate is its own (eth2 at 2500)": (wk1["wan_link_dev"], wk1["wan_link_mbit"]) == ("eth2", 2500),
    "wan: the plain DHCP port of the default answers the same way (eth0 at 1000)": (d["wan_link_dev"], d["wan_link_mbit"]) == ("eth0", 1000),
    "wan: PPPoE over a VLAN - the rate is the 2500 the kernel really answers on eth2.848, the PORT is eth2 below it": (wpppoe["wan_link_dev"], wpppoe["wan_link_mbit"]) == ("eth2", 2500),
    "wan: the counters belong to the port - 120 dropped on eth2, never the 174 the VLAN above it drops on its own": wan_keys(wpppoe, "wan_rx_dropped", "wan_rx_errors", "wan_tx_errors", "wan_tx_dropped") == [120, 3, 1, 2],
    "wan: the link flap counter belongs to the port too - 4 on eth2, while the ppp netdev carrying the traffic says 0": (
        wpppoe["wan_carrier_down_count"] == 4),
    "wan: a DSA port reports its own flaps (7), the conduit below it is never asked": wk5["wan_carrier_down_count"] == 7,
    "wan: a bridge over ONE port is descended (br-wan -> eth2)": (wk2["wan_link_dev"], wk2["wan_link_mbit"]) == ("eth2", 2500),
    "wan: a bridge over TWO ports has no single port - the rate is the bridge's 2500 and every port counter is null": (
        (wk3["wan_link_mbit"], wk3["wan_link_dev"]) == (2500, None)
        and wan_keys(wk3, "wan_rx_errors", "wan_tx_errors", "wan_rx_dropped", "wan_tx_dropped", "wan_carrier_down_count") == [None] * 5),
    "wan: a lone ppp netdev answers nothing at all - no rate, no port, and no zero in their place": (
        wan_keys(wk4, "wan_link_mbit", "wan_link_dev", "wan_rx_errors", "wan_rx_dropped", "wan_carrier_down_count") == [None] * 5),
    "wan: a DSA port whose carrier is down IS the port, and its -1 is an answer - not the 1000 of the conduit below it": (
        (wk5["wan_link_dev"], wk5["wan_link_mbit"]) == ("wan", None)
        and (wk5["wan_rx_errors"], wk5["wan_rx_dropped"]) == (9, 11)),
    "wan: without a netifd interface there is no port and no counter, only nulls": (
        wan_keys(d3, "wan_link_dev", "wan_link_mbit", "wan_rx_errors", "wan_rx_dropped", "wan_carrier_down_count") == [None] * 5),
    # --- W-A3 per-core CPU (WAN 3.1.2; WAN e2e #6) ---
    "wan: the first run has no earlier sample, so the whole per-core block is null": (
        wan_keys(d1, "cpu", "cpu_cores", "cpu_core_max_pct", "cpu_core_max_index", "cpu_core_max_softirq_pct") == [None] * 5),
    "wan: the BUSIEST core is reported, not the average - core 0 at 98.2 % while the aggregate of the same snapshot says 52.4": (
        wan_keys(d, "cpu_core_max_pct", "cpu_core_max_index", "cpu", "cpu_cores") == [98.2, 0, 52.4, 2]),
    "wan: the packet-path share of that core is 95.5 %, irq and softirq of the same interval": d["cpu_core_max_softirq_pct"] == 95.5,
    "wan: counters that did not move are not a measurement - the run right after reports null again": (
        wan_keys(d2b, "cpu", "cpu_cores", "cpu_core_max_pct", "cpu_core_max_index", "cpu_core_max_softirq_pct") == [None] * 5),
    "wan: a sample older than the one before it (another root) is null, never a negative delta": wan_keys(d4, "cpu", "cpu_core_max_pct", "cpu_cores") == [None] * 3,
    # --- W-A3 WAN byte rates (WAN 3.1.3; WAN e2e #8) ---
    "wan: the rate is null on the first run and a number on the second - 11.2 / 1.6 Mbit/s over 11.00 s of UPTIME, not of the clock": (
        (d1["wan_rx_mbps"], d1["wan_tx_mbps"]) == (None, None) and (d["wan_rx_mbps"], d["wan_tx_mbps"]) == (11.2, 1.6)),
    "wan: the rate is measured on the l3 device - 100.0 / 10.0 on pppoe-wan, not on the port eth2 with its 0.7 GB more": (
        (wpppoe["wan_rx_mbps"], wpppoe["wan_tx_mbps"]) == (100.0, 10.0)),
    "wan: a state that names another device gives no rate, however complete it is": (wk1["wan_rx_mbps"], wk1["wan_tx_mbps"]) == (None, None),
    # --- W-A3 conntrack event counters (WAN 3.1.4; WAN e2e #7) ---
    "wan: the real conntrack capture has no drops - three measured zeros, which is not the same as null": (
        wan_keys(d1, "conntrack_insert_failed", "conntrack_drop", "conntrack_early_drop") == [0, 0, 0]),
    "wan: columns 10-12 are summed over both CPUs and read as HEX - 3 / 1 / 18, where a decimal 0x12 would say 12": (
        wan_keys(d, "conntrack_insert_failed", "conntrack_drop", "conntrack_early_drop") == [3, 1, 18]),
    "wan: a conntrack file whose header does not name the three columns is not read at all, however much hex it holds": (
        wan_keys(wk4, "conntrack_insert_failed", "conntrack_drop", "conntrack_early_drop") == [None] * 3),
    "wan: a kernel without the conntrack file reports null, not zero": (
        wan_keys(d3, "conntrack_insert_failed", "conntrack_drop", "conntrack_early_drop") == [None] * 3),
    "wan: 0.1.7 sends no top-level softnet key (they live in the probe diagnostics)": not [k for k in d if k.startswith("softnet")],
    # --- W-A1 the speedtest pick-up (WAN 3.1.7, 3.1.6; WAN e2e #1-#4a, #13) ---
    "speed: 1850.23 Mbit/s arrives as 1850.23 - the result is Mbit/s, there is no bytes-per-second heuristic":
        d1["speedtests"][0]["download_mbps"] == 1850.23 and d1["speedtests"][0]["upload_mbps"] == 902.4,
    "speed: the client block never leaves the router - no client, no address, no share, no backend url in any payload":
        not re.search(r'"client"|198\.51\.100|"share"|speed\.example', payload_text),
    "speed: a result carries its server name, its bytes and who started it; a missing upload is null, not 0":
        [(i["server"], i["bytes_received"], i["bytes_sent"], i["started_by"], i["iface"], i["link_mbit"], i["diagnostics"])
         for i in d1["speedtests"]] ==
        [("Prague, Czech Republic (CESNET)", 2531000000, 1692000000, "turris", None, 1000, {"v": 1, "cpu_measured": False}),
         ("Praha (CESNET)", 1200000000, 900000000, "turris", None, 1000, {"v": 1, "cpu_measured": False}),
         ("Brno", 500000000, None, "turris", None, 1000, {"v": 1, "cpu_measured": False})]
        and d1["speedtests"][2]["upload_mbps"] is None,
    "speed: the tool is named only where the file proves it - the tls block is the Rust port, the Go file stays null":
        [i["tool"] for i in d1["speedtests"]] == [None, "rust", None],
    "speed: a file without a speed is not a result - four files, three items":
        len(d1["speedtests"]) == 3,
    "speed: the results directory is the uci option; the hard-coded default is used only when uci cannot answer":
        stamps(d1) == ["2026-09-20T05:23:41+02:00", "2026-09-20T05:41:02+02:00", "2026-09-20T06:02:00+02:00"]
        and stamps(wspeedfb) == ["2019-01-01T00:00:00+01:00"],
    "speed: a dry run commits nothing - the next run offers the same three results again":
        stamps(d) == stamps(d1),
    "speed: sixty results, fifty leave, oldest first":
        len(wspeed60["speedtests"]) == 50
        and stamps(wspeed60)[0] == "2026-09-19T01:00:00+02:00"
        and stamps(wspeed60)[-1] == "2026-09-19T01:49:00+02:00",
    "speed: W01 repair - the old /tmp state file is deleted, not migrated, so the older results go out once more":
        stamps(wspeedold) == stamps(d1) and text("wspeedold_state.txt") == "no",
    "speed: a report that never arrived commits nothing - pending.state stays and every item is offered again":
        text("wack1_pending.txt") == "yes" and stamps(wack[0]) == stamps(d1) and stamps(wack[1]) == stamps(d1),
    "speed: a bare 200 is not a receipt - an answer without speedtests_acked sends everything again":
        stamps(wack[1]) == stamps(d1),
    "speed: an ack naming the second of three leaves only the third":
        stamps(wack[2]) == stamps(d1) and stamps(wack[3]) == ["2026-09-20T06:02:00+02:00"],
    "speed: an ack for a timestamp this report never sent is no answer to it":
        stamps(wack[4]) == ["2026-09-20T06:02:00+02:00"]
        and stamps(wack[5]) == [] and text("wack5_sent.txt") == "yes",
    "speed: speedtest_active is an interval flag - true while results are new or a client runs, false on the run after":
        d1["speedtest_active"] is True and wack[5]["speedtest_active"] is False
        and wactive["speedtest_active"] is True and wactive["speedtests"] == [],
    "speed: one result stays under 400 B on the wire":
        max(len(json.dumps(i, separators=(",", ":"))) for i in d1["speedtests"]) <= 400,
    "uplink: a result nobody saw start (there before the first run) says null, never a guess (wupl1, r2)":
        [uplink(i) for i in wupl[1]["speedtests"]] == [(None, None, None)]
        and all(uplink(i) == (None, None, None) for i in d1["speedtests"]),
    "uplink: the night test that the modem port counted is backup, eth3, on the counters' evidence (wupl3)":
        uplink(by_stamp(wupl[3], "2026-09-25T03:10:00+02:00")) == ("backup", "counters", "eth3"),
    "uplink: offered again it keeps the verdict of the run that saw it start (wupl4, wupl6)":
        uplink(by_stamp(wupl[4], "2026-09-25T03:10:00+02:00")) == ("backup", "counters", "eth3")
        and uplink(by_stamp(wupl[6], "2026-09-25T03:10:00+02:00")) == ("backup", "counters", "eth3"),
    "uplink: the test the WAN counted with the modem idle is wan, eth0 (wupl6)":
        uplink(by_stamp(wupl[6], "2026-09-25T03:20:00+02:00")) == ("wan", "counters", "eth0"),
    "uplink: counters that went backwards prove nothing - null (wupl7)":
        uplink(by_stamp(wupl[7], "2026-09-25T03:30:00+02:00")) == (None, None, None),
    "uplink: proto is the scheme of server.url only, null without one, and the url never leaves (wupl7)":
        [i["proto"] for i in wupl[7]["speedtests"]] == ["https", "http", "https", None]
        and "speed.example" not in json.dumps(wupl[7]["speedtests"]),
    # --- W-A4 the path the packets take (WAN 3.1.5 with X5; WAN e2e #9, #21) ---
    # The ubus device dump is no longer part of this: the switch is read every
    # run (see the "lan:" checks), and the hourly block reuses that one walk.
    "wan: the path state is read once an hour - six payload runs, one read of each uci option":
        [uci_asked[k] for k in ("-q get firewall.@defaults[0].flow_offloading",
                                "-q get network.@globals[0].packet_steering",
                                "-q show sqm")] == [1, 1, 1]
        and path_of(d1, "checked_at") == path_of(d5, "checked_at"),
    "wan: packet steering is the runtime mask of every RX queue, never the uci label - rx-0 = 2 with two empty queues is on":
        (path_of(wpath[0], "packet_steering"), path_of(wpath[0], "packet_steering_active"), path_of(wpath[0], "wan_rps_mask"))
        == ("unset", True, "2")
        and (path_of(d1, "packet_steering"), path_of(d1, "packet_steering_active"), path_of(d1, "wan_rps_mask"))
        == ("unset", False, "0")
        and (path_of(wpath[2], "packet_steering"), path_of(wpath[2], "packet_steering_active")) == ("0", True),
    "wan: a port whose RX queues the kernel does not expose answers unknown, not off":
        path_of(wk5, "packet_steering_active") is None and path_of(wk5, "wan_rps_mask") is None
        and wk5["wan_link_dev"] == "wan",
    "wan: with no physical port there is nothing to read the path state from":
        [path_of(wk3, k) for k in ("packet_steering_active", "wan_rps_mask", "wan_threaded_napi", "wan_rx_ring_drops")]
        == [None] * 4 and wk3["wan_link_dev"] is None,
    "wan: threaded NAPI is read from the port itself":
        path_of(wpath[0], "wan_threaded_napi") is False,
    "wan: ring drops are rx_discard + rx_overrun (5 + 2); a driver without those names answers null, never 0":
        path_of(wpath[0], "wan_rx_ring_drops") == 7
        and path_of(wpath[1], "wan_rx_ring_drops") is None
        and path_of(wpath[3], "wan_rx_ring_drops") is None and wpath[3]["agent_tools"]["ethtool"] is False
        and path_of(d1, "wan_rx_ring_drops") is None and d1["agent_tools"]["ethtool"] is False,
    "wan: flow offloading is configuration and the flowtable is the kernel - both are read, neither is assumed":
        [path_of(wpath[0], k) for k in ("flow_offloading", "flow_offloading_hw", "flowtable_active")] == [True, False, True]
        and [path_of(wpath[2], k) for k in ("flow_offloading", "flowtable_active")] == [False, False]
        and path_of(wpath[3], "flowtable_active") is None,
    "wan: SQM is the enabled queue on the WAN CHAIN - a queue on eth2 counts for a WAN on pppoe-wan, the stale LAN one never":
        path_of(wpath[0], "sqm") == [{"iface": "eth2", "download_kbps": 50000, "upload_kbps": None,
                                      "egress_dropped": 12, "ingress_dropped": 34}]
        and path_of(wpppoe, "sqm") == path_of(wpath[0], "sqm")
        and path_of(d1, "sqm") == [],
    "wan: a shaping rate of 0 means that direction is not shaped, not 0 kbit/s":
        path_of(wpath[0], "sqm")[0]["upload_kbps"] is None and wpath[0]["sqm_upload_kbps"] is None,
    "wan: egress and ingress drops come from two different qdiscs; without tc both are null":
        path_of(wpath[3], "sqm") == [{"iface": "eth2", "download_kbps": 50000, "upload_kbps": None,
                                      "egress_dropped": None, "ingress_dropped": None}]
        and wpath[3]["agent_tools"]["tc"] is False and d1["agent_tools"]["tc"] is True,
    "wan: a router with no SQM configuration says nothing - null, not 'switched off'":
        path_of(wpath[4], "sqm") is None and wpath[4]["sqm_enabled"] is None
        and all(wpath[4][k] is None for k in ("sqm_download_kbps", "sqm_upload_kbps", "sqm_dropped"))
        and d1["sqm_enabled"] is False,
    # INDEX section 4, NEW: the owner's file holds one stale, DISABLED section.
    # wpath1 proves the chain match (the section names eth1, the WAN is eth2),
    # so the `enabled` flag needs a queue that names the WAN port itself and is
    # switched off - configured once is not shaping now.
    "wan: a disabled sqm section is not a shaper, even when it names the WAN port itself":
        path_of(wpath[7], "sqm") == [] and wpath[7]["sqm_enabled"] is False
        and all(wpath[7][k] is None for k in ("sqm_download_kbps", "sqm_upload_kbps", "sqm_dropped"))
        and wpath[7]["wan_link_dev"] == "eth2",
    "wan: the legacy sqm keys follow the WAN queue, not the first section of the file":
        (wpath[0]["sqm_enabled"], wpath[0]["sqm_download_kbps"], wpath[0]["sqm_dropped"]) == (True, 50000, 12)
        and d1["sqm_download_kbps"] is None,
    "wan: the LAN cap is a capability and the LAN max is the current state - lan1 at 100 does not lower the cap":
        [path_of(d1, k) for k in ("lan_port_max_mbit", "lan_port_cap_mbit")] == [1000, 1000]
        and path_of(d1, "lan_conduits") == [{"dev": "eth1", "mbit": 1000}],
    "wan: capability is not the current state - with lan0's cable out the fastest LINKED port is 100, the cap stays 1000":
        [path_of(wpath[6], k) for k in ("lan_port_max_mbit", "lan_port_cap_mbit")] == [100, 1000]
        and path_of(wpath[6], "lan_conduits") == [{"dev": "eth1", "mbit": 1000}],
    "wan: only bridge members count for the LAN cap - eth3, the USB modem at 150H, is no LAN port":
        path_of(d1, "lan_port_max_mbit") == 1000 and path_of(wpath[6], "lan_port_max_mbit") == 100
        and "150" not in json.dumps(path_of(d1, "lan_conduits")),
    "wan: without ubus the LAN side is unknown, not empty":
        [path_of(wpath[5], k) for k in ("lan_port_max_mbit", "lan_port_cap_mbit", "lan_conduits")] == [None] * 3,
    # --- the wired switch ports (lan_ports) ---
    "lan: the owner's switch, port by port - link, rate, duplex and what each port supports":
        [(q.get("name"), q.get("link"), q.get("speed_mbit"), q.get("duplex"), q.get("max_mbit")) for q in lan_ports(d1)] == [
            ("lan0", True, 1000, "full", 1000), ("lan1", True, 100, "full", 1000),
            ("lan2", False, None, None, 1000), ("lan3", False, None, None, 1000),
            ("lan4", True, 1000, "full", 1000)],
    "lan: a port without carrier prints no speed, so the rate and the duplex are null - never 0":
        [(q.get("speed_mbit"), q.get("duplex")) for q in lan_ports(d1) if not q.get("link")] == [(None, None)] * 2,
    "lan: lan1 at 100 is the partner's limit, not a fault - the port supports 1000 and the other end advertises 100":
        lan_port(d1, "lan1").get("partner_max_mbit") == 100
        and lan_port(d1, "lan1").get("max_mbit") == 1000
        and lan_port(d1, "lan0").get("partner_max_mbit") == 1000,
    "lan: an unplugged port has no link partner to advertise anything":
        [q.get("partner_max_mbit") for q in lan_ports(d1) if not q.get("link")] == [None, None],
    "lan: devices are counted per port, and one MAC learnt in two VLANs is one device":
        [(q.get("name"), q.get("clients")) for q in lan_ports(d1)] == [
            ("lan0", 3), ("lan1", 1), ("lan2", 0), ("lan3", 0), ("lan4", 2)]
        and (d1.get("lan_ports") or {}).get("clients_total") == 6,
    "lan: the rows that are not a client are dropped - permanent, vlan 4095 and the router's own addresses":
        lan_port(d1, "lan2").get("clients") == 0 and lan_port(d1, "lan3").get("clients") == 0,
    # The stub carries three of these WITHOUT `permanent` (lan0 a solicited-node
    # group, lan4 SSDP, lan3 broadcast), so the permanent rule cannot cover for
    # this one: lan0 stays 3, lan4 stays 2 and lan3 stays 0.
    "lan: a multicast or broadcast group is not a device, even when the row is not `permanent`":
        (lan_port(d1, "lan0").get("clients"), lan_port(d1, "lan4").get("clients"),
         lan_port(d1, "lan3").get("clients")) == (3, 2, 0),
    "lan: only the switch's own ports are ports - the radios and the conduit are bridge members, not lan ports":
        [q.get("name") for q in lan_ports(d1)] == ["lan0", "lan1", "lan2", "lan3", "lan4"]
        and (d1.get("lan_ports") or {}).get("clients_total") == 6,
    "lan: the conduit every wired client shares is carried with its own rate":
        (d1.get("lan_ports") or {}).get("conduits") == [{"dev": "eth1", "link": True, "speed_mbit": 1000, "duplex": "full"}]
        and (d1.get("lan_ports") or {}).get("bridge") == "br-lan",
    "lan: both gigabit cables out - two ports lose the link and their rate, the third still links at 100":
        [(q.get("name"), q.get("link"), q.get("speed_mbit")) for q in lan_ports(wpath[6]) if q.get("name") in ("lan0", "lan1", "lan4")]
        == [("lan0", False, None), ("lan1", True, 100), ("lan4", False, None)],
    "lan: a switch with nothing plugged in reads a measured 0 on every port, not null":
        [q.get("clients") for q in lan_ports(wport1)] == [0] * 5
        and (wport1.get("lan_ports") or {}).get("clients_total") == 0
        and [q.get("name") for q in lan_ports(wport1)] == ["lan0", "lan1", "lan2", "lan3", "lan4"],
    "lan: without `bridge` the router cannot say which port a device is on - the section is null, not an empty list":
        wport2.get("lan_ports") is None and wport2["version"] == d1["version"],
    "lan: without ubus there are no ports to report either":
        wport3.get("lan_ports") is None,
    "lan: not one MAC address leaves the router - the counts are built and thrown away inside awk":
        not re.search(r'"[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}"', json.dumps([p.get("lan_ports") for p in (d1, d, wpath[6], wport1)])),
    "lan: the whole port section stays under 800 B on the wire":
        len(json.dumps(d1.get("lan_ports"), separators=(",", ":"))) <= 800,
    "lan: the switch is read every run, not once an hour - r2b reports it although the WAN path came from the cache":
        d2b.get("lan_ports") == d1.get("lan_ports") and d2b["wan_path"] == d1["wan_path"],
    "lan: one ubus device dump per payload run and never two, and no fdb read at all when there is no dump":
        (dev_dumps, fdb_reads) == (6, 5),
    "wan: the whole path object stays under 600 B on the wire":
        len(json.dumps(d1["wan_path"], separators=(",", ":"))) <= 600,
    # WAN e2e #14, the minute half (a probe item is wave 2). Measured on the
    # run where every value is a real one, not a null: nulls are the cheap case.
    "payload budget: the new top-level keys and wan_path stay under 1100 B for a full run":
        "MISSING" not in wan_keys(d, *WAN_NEW_KEYS)
        and len(json.dumps({k: d[k] for k in WAN_NEW_KEYS}, separators=(",", ":"))) <= 1100,
    # G20, WAN e2e #13a: the firewall signal
    "gap: the firewall is the fw4 table in the kernel, not any ruleset - mwan3 alone is not a firewall":
        d1["firewall_enabled"] is True and wfw1["firewall_enabled"] is False,
    "gap: an nft that answers with an empty kernel says the rules are NOT loaded, although init.d calls the service enabled":
        wfw2["firewall_enabled"] is False,
    "gap: no nft and no iptables is unknown, not off - and still not what init.d claims":
        wfw3["firewall_enabled"] is None,
    # G24: the five claim-defaults (sqm_enabled is the wpath5 check above)
    "gap: nothing is claimed about the DNS resolver when none of them was found":
        [d1[k] for k in ("dns_engine", "dns_encryption", "dns_servers")] == [None, None, None],
    "gap: the WAN reconnect counter is null until two samples have been compared, then a measured 0":
        d1["wan_reconnect_count"] is None and d["wan_reconnect_count"] == 0,
    # G30: the router's own clock
    "gap: every report carries the router's own clock, read again in each run":
        isinstance(d1["agent_time"], int) and d["agent_time"] - d1["agent_time"] >= 11
        and abs(d1["agent_time"] - os.path.getmtime(f"{out}/r1.json")) < 300,
    # G41, WAN e2e #15: the DNS probe keeps its exit status
    "gap: a refused lookup is not a latency - the resolver answers false and the time is null":
        wdns1["dns_resolver_ok"] is False and wdns1["dns_latency_ms"] is None,
    "gap: a lookup that answered gives true AND a number (busybox time writes to the timed command's stderr)":
        d1["dns_resolver_ok"] is True and isinstance(d1["dns_latency_ms"], int),
    "gap: with no resolver client on PATH both the answer and the time are null":
        [wdns3["dns_resolver_ok"], wdns3["dns_latency_ms"]] == [None, None],
    # G42, WAN e2e #16: the run's own clock and the runs that sent nothing
    "gap: the run's length comes from the kernel uptime - 4.20 s of it are 4200 ms":
        wrun5["agent_run_ms"] == 4200,
    "gap: without an uptime to read the run cannot time itself and says null, not 0":
        wrun7["agent_run_ms"] is None,
    "gap: the previous run's total, its POST included, arrives with the NEXT report":
        wrun5["agent_prev_total_ms"] is None and wrun6["agent_prev_total_ms"] == 4200,
    "gap: a run that met a live lock writes no report at all, and the next one counts it":
        text("wrun1.json") == "" and (wrun2["runs_skipped_lock"], wrun2["runs_skipped_post"]) == (1, 0),
    "gap: a POST that never arrived is counted the same way":
        (wrun3["runs_skipped_lock"], wrun3["runs_skipped_post"]) == (1, 1),
    "gap: an accepted report clears exactly the skips it carried, and 0 is then measured":
        (wrun4["runs_skipped_lock"], wrun4["runs_skipped_post"]) == (0, 0)
        and (d1["runs_skipped_lock"], d1["runs_skipped_post"]) == (0, 0),
    # WAN e2e #17
    "gap: identity cache is data, not code - a planted cache in either place runs nothing, the router keeps its name": not os.path.exists(f"{out}/PWNED") and (w17a["hostname"], w17a["model"]) == ("turris", "Turris Omnia"),
    "gap: identity cache is data, not code - shell code inside a well-formed cache arrives as text": (w17b["hostname"], w17b["model"]) == ("$(touch /work/out/PWNED)", "`touch /work/out/PWNED`"),
    "gap: identity cache older than 24 h is read again": (w17c["hostname"], w17c["model"]) == ("turris", "Turris Omnia"),
    # WAN e2e #18
    "gap: last payload is private and keyless - 0600 inside a 0700 directory": text("w18_mode.txt") == "-rw-------" and text("w18_dirmode.txt") == "drwx------",
    "gap: last payload is private and keyless - the key is sent, and is in no file under /tmp or the private directory": w18["agent_key"] == "SECRETKEY123" and text("w18_keyfiles.txt") == "",
    "gap: last payload is private and keyless - the world-readable copy of 0.1.6 is removed and not written again": text("w18_oldfile.txt") == "no" and text("w18b_oldfile.txt") == "no",
    "gap: last payload is private and keyless - the kept copy is the payload with a blank key": w18_kept == {**w18, "agent_key": ""},
    "gap: last payload is private and keyless - a key with a quote in it leaves no piece behind": w18b["agent_key"] == 'abc"SECRETKEY123' and text("w18b_keyfiles.txt") == "" and w18b_kept == {**w18b, "agent_key": ""} and text("w18b_mode.txt") == "-rw-------",
    # WAN e2e #23
    "gap: a version change drops the relocated identity cache, in either place of the private directory": (w18["hostname"], w18["model"]) == ("turris", "Turris Omnia") and text("w23_fallback.txt") == "no",
    "gap: a version change drops the relocated identity cache - and the stamp then reads the running version": text("w23_stamp.txt") == w18["version"] != "0.0.0",
    "gap: a version change drops every cache a new parser would read back (Wi-Fi, disks, SMART, WAN path, rates, the old speedtest state) - and nothing else: probe counters and unsent results stay": (text("w23_stale.txt") or "").splitlines() == [f"/tmp/status-agent-openwrt-private/{f}" for f in ("pending.state", "probe-out/1.json", "probe.attempts", "probe.count", "skipped")],
    # WAN e2e #19
    "gap: remote actions - positive control: signed and allowed, restart_wan runs": act_calls.get("w19_1") == ["/sbin/ifdown wan", "/sbin/ifup wan"] and act_results.get("w19_1") == ["1|executed|WAN restartovano"],
    "gap: remote actions - what the agent signs is action|ts|nonce of the answer": signed.get("w19_1") == [f"action=restart_wan|ts={resp1['timestamp']}|nonce={resp1['nonce']}"],
    "gap: remote actions are single-use - the same nonce within 60 s is refused, no second ifdown": refused("w19_2", "nonce"),
    "gap: remote actions are allow-listed - signed reboot_router off the list is refused, no reboot": refused("w19_3", "ALLOWED_ACTIONS"),
    "gap: remote actions - a wrong signature runs nothing": refused("w19_4", "HMAC"),
    "gap: remote actions - a signature 100 s old runs nothing and is not even checked": refused("w19_5", "30s") and signed.get("w19_5") == [],
    "gap: remote actions - positive control: restart_service restarts a plain name (list written with a space)": act_calls.get("w19_6") == ["/etc/init.d/dnsmasq restart"] and act_results.get("w19_6", [""])[0].startswith("6|executed|"),
    "gap: remote actions are path-safe - service_name ../x is refused, nothing under init.d is called": refused("w19_7", "sluzby"),
    "gap: remote actions are allow-listed - an empty ALLOWED_ACTIONS allows nothing": refused("w19_8", "ALLOWED_ACTIONS"),
    "gap: remote actions are allow-listed - a cfg without the line keeps the default list": act_results.get("w19_11") == ["11|executed|DHCP najem na WAN obnoven"],
    "gap: remote actions are single-use - a nonce used 100 s ago is free again": act_results.get("w19_9") == ["9|executed|DHCP najem na WAN obnoven"],
    "gap: remote actions - a timestamp that is not a number runs nothing, signs nothing and does not end the run": text("w19_10_exit.txt") == "0" and act_calls.get("w19_10") == [] and act_results.get("w19_10") == [] and signed.get("w19_10") == [] and "arithmetic" not in (text("w19_10.err") or ""),
    "gap: private directory planted as a symlink in both places - replaced by a real 0700 directory, nothing written behind the link": text("wpriv_dirmode.txt") == "drwx------" and text("wpriv_mode.txt") == "-rw-------" and text("wpriv_planted.txt") == "" and load("wpriv.json").get("version") == d["version"],
    "gap: the response seam is read on one line, and that line asks for --dry-run": (text("seam_guard.txt") or "").splitlines() == ['[ "$DRY_RUN" = "1" ] && [ -n "$STATUS_TEST_RESPONSE" ] && BK_TEST_RESPONSE="$STATUS_TEST_RESPONSE"'],
    "gap: a run on a canned answer still prints the whole payload": all(load(f"w19_{i}.json").get("version") == d["version"] for i in range(1, 12)),
}

# --- W1-C3: the error lines behind log_errors_24h (wlog1..wlog8) ---
# bin/logread writes the pii and formats logs relative to its own clock and
# notes that clock; every ts below is exact to the second.
def stub_now(name):
    """The clock of the ONE logread call noted in NAME; more than one call
    means the run is not the one the expectations were written for."""
    rows = (text(name) or "").splitlines()
    try:
        return int(rows[0].split()[1]) if len(rows) == 1 else None
    except (IndexError, ValueError):
        return None
wl = {i: payload(f"wlog{i}") for i in range(1, 10)}
n1, n2 = stub_now("wlog1_now.txt"), stub_now("wlog2_now.txt")
LOG_KEYS = ("log_errors_24h", "log_warnings_24h", "log_window_secs", "log_errors_recent", "log_lines_state")
exp_pii = None if n1 is None else [
    {"ts": n1 - 600, "prog": "kresd", "msg": 'error resolving <host>. asked by <host>, <host> and <host>: "quote" back\\slash ?? ?', "count": 1},
    {"ts": n1 - 1200, "prog": "dnsmasq-dhcp", "msg": "DHCPACK(br-lan) <ipv4> <mac> <host>", "count": 1},
    {"ts": n1 - 1800, "prog": "odhcpd", "msg": "Failed to send reply to <ipv6>%br-lan (DUID <id>, <ipv6>)", "count": 1},
    {"ts": n1 - 2400, "prog": "hostapd", "msg": "wlan0: STA <mac> IEEE 802.1X: authentication failed for identity <email>", "count": 1},
    # Cut at 197 + "...": the address sat across the cut and is a whole tag.
    {"ts": n1 - 3000, "prog": "dnsmasq", "msg": "error: " + "x" * 182 + " <ipv4> ...", "count": 2},
]
exp_fmt = None if n2 is None else [
    {"ts": None, "prog": None, "msg": "error: continuation of a stack trace", "count": 1},
    {"ts": n2 - 600, "prog": "uhttpd", "msg": "error: TLS handshake failed", "count": 3},
    {"ts": n2 - 1800, "prog": "crond", "msg": "fatal: cannot open crontab", "count": 1},
    {"ts": n2 - 2400, "prog": "procd", "msg": "Instance ntpd::instance1 s in a crash loop 6 crashes, 0 seconds since last crash", "count": 1},
    # The printk stamp is dropped: ts is the time, and a stamp would split repeats.
    {"ts": n2 - 3000, "prog": "kernel", "msg": "mv88e6085 f1072004.mdio-mii:10: error: link down", "count": 1},
]
n9 = stub_now("wlog9_now.txt")
exp_cut = None if n9 is None else [
    {"ts": n9 - 60, "prog": "uhttpd", "msg": "error: ...", "count": 1},
    {"ts": n9 - 120, "prog": "dnsmasq", "msg": "error: " + " ".join(["<ipv4>"] * 16) + " ...", "count": 1},
    {"ts": n9 - 297, "prog": "kernel", "msg": "mt7915e 0000:01:00.0: error: message timeout", "count": 3},
]
# The plain stub log: fixed dates, read in the container's UTC.
exp_r2 = [
    {"ts": 1788339902, "prog": "dnsmasq", "msg": "failed to create listening socket", "count": 1},  # 2026-09-02 09:05:02Z
    {"ts": 1788339603, "prog": "odhcpd", "msg": "Failed to send RS", "count": 1},  # 09:00:03Z
]
# Every identifier the pii log plants. None may be anywhere in a report, and
# no piece of a cut address may be in the lines.
PLANTED = ("192.0.2.44", "198.51.100.23", "192.0.2.61", "02:5e:10", "02-5e-10", "025e10", "fe80::1c2",
           "2001:db8:42", "000100012b3c4d5e", "jana", "novakova", "example.org", "novakovi", "iphone",
           "desktop-7qk2m9a", "galaxy")
leaked_log = sorted(
    f"{f}: {s}" for f in [f"wlog{i}.json" for i in range(1, 10)] + ["wlog1_last.json"]
    for s in PLANTED if s in (text(f) or "").lower())
all_lines = [x for p in (d, wl[1], wl[2], wl[4], wl[7], wl[9]) for x in (p.get("log_errors_recent") or [])]
checks.update({
    "log: výchozí log routeru - obě chybové řádky s časem, programem a zprávou, okno od prvního řádku (r2)":
        d["log_errors_recent"] == exp_r2 and d["log_lines_state"] == "on"
        and isinstance(d["log_window_secs"], int) and 0 <= d["agent_time"] - d["log_window_secs"] - 1788339601 <= 60,
    "log: maskované řádky - MAC, IPv6, IPv4, e-mail, DUID, domácí doména, jména zařízení i klient DHCP; nejnovější první, stejná chyba jednou s počtem 2 (wlog1)":
        exp_pii is not None and wl[1]["log_errors_recent"] == exp_pii,
    "log: počty a okno z téhož průchodu - 6 chyb, 1 varování, okno 2 h k nejstaršímu řádku (wlog1)":
        (wl[1]["log_errors_24h"], wl[1]["log_warnings_24h"]) == (6, 1)
        and n1 is not None and isinstance(wl[1]["log_window_secs"], int) and 7200 - 60 <= wl[1]["log_window_secs"] <= 7200,
    "log: žádná zasazená adresa, MAC, e-mail ani jméno není v žádném hlášení ani v uložené kopii":
        leaked_log == [] and text("wlog1_last.json") is not None,
    "log: řez na 200 znaků jde až po maskování - v řádcích není ani kus adresy":
        not re.search(r"192\.0|198\.51|\d+\.\d+\.\d+\.\d+", json.dumps([x["msg"] for x in all_lines])) and len(all_lines) == 25,
    "log: každý řádek je tisknutelné ASCII o nejvýš 200 znacích":
        all(len(x["msg"]) <= 200 and all(32 <= ord(c) < 127 for c in x["msg"]) for x in all_lines),
    "log: každý formát data dá správný čas i v CEST - logd, ISO 8601 se Z i s +02:00, BSD bez roku; řádek bez data má ts i program null; 'ntpd::' není IPv6 (wlog2)":
        exp_fmt is not None and wl[2]["log_errors_recent"] == exp_fmt,
    "log: jen 5 nejnovějších různých řádků, dva starší zůstanou doma; okno sahá k nejstaršímu (ISO se Z) a počítá všech 9 (wlog2)":
        wl[2]["log_errors_24h"] == 9 and isinstance(wl[2]["log_window_secs"], int) and 5400 - 60 <= wl[2]["log_window_secs"] <= 5400
        and not any("Failed to send RS" in x["msg"] or "bind to" in x["msg"] for x in wl[2]["log_errors_recent"] or []),
    "log: LOG_LINES_ENABLED=0 na routeru - žádné řádky, počty a okno jdou dál (wlog3)":
        wl[3]["log_errors_recent"] is None and wl[3]["log_lines_state"] == "off_router"
        and (wl[3]["log_errors_24h"], wl[3]["log_warnings_24h"]) == (6, 1) and isinstance(wl[3]["log_window_secs"], int),
    "log: odpověď \"log_lines\":false - toto hlášení řádky už neslo, vypínač se uloží na flash (wlog4)":
        wl[4]["log_lines_state"] == "on" and len(wl[4]["log_errors_recent"] or []) == 5 and text("wlog4_flag.txt") == "yes",
    "log: vypnuto u monitoru - další hlášení bez řádků i po čistém privátním adresáři, odpověď bez klíče nic nemění (wlog5)":
        wl[5]["log_errors_recent"] is None and wl[5]["log_lines_state"] == "off_monitor"
        and (wl[5]["log_errors_24h"], wl[5]["log_warnings_24h"]) == (6, 1) and text("wlog5_flag.txt") == "yes",
    "log: \"log_lines\": true (s mezerou) - toto hlášení ještě bez řádků, vypínač pak zmizí (wlog6)":
        wl[6]["log_errors_recent"] is None and wl[6]["log_lines_state"] == "off_monitor" and text("wlog6_flag.txt") == "no",
    "log: po zapnutí se řádky vrátí (wlog7)":
        wl[7]["log_lines_state"] == "on" and len(wl[7]["log_errors_recent"] or []) == 5,
    "log: dlouhé řádky se před maskami zkrátí na 256 znaků u mezery (z 17. adresy nezbude kus), slovo bez mezery zmizí celé, opakovaná chyba jádra s jiným razítkem printk je jeden řádek s počtem 3 (wlog9)":
        exp_cut is not None and wl[9]["log_errors_recent"] == exp_cut and "198.51" not in json.dumps(wl[9]["log_errors_recent"]),
    "log: bez logu jsou všechna pole null - ne 0 a ne [] (wlog8)":
        [wl[8][k] for k in LOG_KEYS] == [None, None, None, None, "on"],
})
# --- WW-07, IO-03, IO-11, WW-04, IO-07: waits and writes ---
# (openwrt-stubs/run-in-container.sh: wtake*, wskip*, wlp*, wdl*, wupd*)
def maybe(name):
    """A payload that may legitimately be missing: None instead of a FAIL."""
    try:
        return json.load(open(f"{out}/{name}.json"))
    except (FileNotFoundError, ValueError):
        return None
def killed(p):
    return None if p is None else [p.get(k) for k in ("runs_skipped_lock", "runs_skipped_post", "runs_skipped_killed")]
def procs(name):
    """'holder=S 123 child=gone' -> {'holder': 'S', 'child': 'gone'} (state only)."""
    return {k: v.split()[0] for k, v in re.findall(r"(\w+)=(\S+(?: \d+)?)", text(name) or "")}
def err(name):
    return text(f"{name}.err") or ""
wt = {n: maybe(f"wtake{n}") for n in ("1", "1b", "1c", "2b", "3", "4")}
ws1, ws2, ws2b, ws2c = maybe("wskip1"), maybe("wskip2"), maybe("wskip2b"), maybe("wskip2c")
wlp1, wlp3 = maybe("wlp1"), maybe("wlp3")
wlp1_kept, wlp3_kept = load_kept("wlp1_last.json"), load_kept("wlp3_last.json")
wdl2 = maybe("wdl2")
ns_core = log_lines("nslookup_calls.log", core_only=True)
wt6a, wt6, wt8 = maybe("wtake6a"), maybe("wtake6"), maybe("wtake8")
try:
    ws1_total = [int(x) for x in (text("wskip1_total.txt") or "").split()]
    ws1_left = int(text("wskip1_left.txt") or "-1")
except ValueError:
    ws1_total, ws1_left = [], -1
try:
    upd_old, upd_new = (int(x) for x in (text("wupd1_sizes.txt") or "").split())
except ValueError:
    upd_old = upd_new = -1
# Read raw: text() strips, and an empty sample (a failed read) must count.
try:
    upd_seen = open(f"{out}/wupd1_seen.txt").read().split("\n")[:-1]
    upd_samples = int(text("wupd1_samples.txt") or "0")
except (FileNotFoundError, ValueError):
    upd_seen, upd_samples = [], 0
checks.update({
    "lock: a holder 400 s old is killed together with its child, and the run goes on and reports it (wtake1)":
        killed(wt["1"]) == [0, 0, 1] and procs("wtake1_procs.txt").get("holder") in ("gone", "Z")
        and procs("wtake1_procs.txt").get("child") in ("gone", "Z") and text("wtake1_lock.txt") == "no"
        and "ukoncuji ho" in err("wtake1"),
    "lock: the takeover goes with the next accepted report and is then a measured 0 (wtake1b, wtake1c)":
        killed(wt["1b"]) == [0, 0, 1] and killed(wt["1c"]) == [0, 0, 0]
        and d1["runs_skipped_killed"] == 0 and d["runs_skipped_killed"] == 0,
    "lock: a holder 30 s old is an ordinary busy minute - no report, nothing killed, the next report counts it (wtake2)":
        text("wtake2.json") == "" and procs("wtake2_procs.txt") == {"holder": "S", "child": "S"}
        and killed(wt["2b"]) == [1, 0, 0],
    "lock: a PID that belongs to another process by now is not killed, and its lock is taken (wtake3)":
        killed(wt["3"]) == [0, 0, 0] and procs("wtake3_procs.txt") == {"holder": "S", "child": "S"}
        and "patri jinemu procesu" in err("wtake3"),
    "lock: a holder that is a zombie already (busybox crond reaps every 10 s) is taken over (wtake4)":
        killed(wt["4"]) == [0, 0, 1] and procs("wtake4_procs.txt") == {"zombie": "Z"},
    "lock: a holder that survives SIGKILL keeps the lock - no report and no second run beside it (wtake5)":
        text("wtake5.json") == "" and (text("wtake5_lock.txt") or "").splitlines() == ["1", "l"]
        and "nejde ukoncit" in err("wtake5"),
    "zámek: po převzetí zaseknutého běhu hlásí další report agent_prev_total_ms i agent_prev_cpu_ms null - ne čísla běhu před ním (wtake6)":
        wt6a is not None and [x.isdigit() for x in (text("wtake6a_files.txt") or "").split()] == [True, True]
        and wt6 is not None and wt6["agent_prev_total_ms"] is None and wt6["agent_prev_cpu_ms"] is None
        and killed(wt6) == [0, 0, 1] and procs("wtake6_procs.txt").get("wedged") in ("gone", "Z"),
    "zámek: běh, jehož zámek mezitím drží jiný běh, ho na konci nesmaže a nepřepíše run.total (wtake7)":
        len((text("wtake7_lock.txt") or "").split()) == 3
        and text("wtake7_lock.txt").split()[0] == text("wtake7_lock.txt").split()[1]
        and text("wtake7_lock.txt").split()[2] == "no-total" and maybe("wtake7") is not None,
    "zámek: běh, který převzetí ukončilo, ale jádro ho ještě drželo, se započítá, až jeho zámek někdo převezme; předek běhu značku nedostane (wtake8, wtake5)":
        killed(wt8) == [0, 0, 1] and text("wtake8_lock.txt") == "no" and text("wtake5_killed.txt") == "no",
    "skipped: 25,000 old lines plus 200 appended during the fold - each counted once, now or by the next run (wskip1)":
        ws1 is not None and ws1["runs_skipped_lock"] >= 25000 and ws1["runs_skipped_post"] == 0
        and ws1_total == [ws1["runs_skipped_lock"], 1, 0] and ws1["runs_skipped_lock"] + ws1_left == 25200
        and text("wskip1_fold.txt") == "no",
    "skipped: each counter stops at 100,000 (the server's range check), lines of an older agent count too (wskip2)":
        killed(ws2) == [100000, 100000, 7] and killed(ws2b) == [100000, 100000, 7] and killed(ws2c) == [0, 0, 0],
    "last payload: a failed POST keeps the copy - private and keyless (wlp1)":
        wlp1 is not None and text("wlp1_mode.txt") == "-rw-------" and wlp1_kept == {**wlp1, "agent_key": ""},
    "last payload: an accepted report removes it, and the owner's flag keeps it on every run (wlp2, wlp3)":
        text("wlp2_file.txt") == "no" and wlp3 is not None and wlp3_kept == {**wlp3, "agent_key": ""},
    "deadline: on time the POST keeps its 20 s and the service checks run (wdl0)":
        "(limit 20 s)" in err("wdl0") and "Odeslany vysledky agent-side kontrol sluzeb." in err("wdl0"),
    "deadline: 40 s late the POST gets 58-40-5 = 13 s and the checks still run (wdl1)":
        "(limit 13 s)" in err("wdl1") and "Odeslany vysledky agent-side kontrol sluzeb." in err("wdl1"),
    "deadline: 50 s late the POST gets its floor of 5 s and the checks wait for the next minute (wdl2)":
        "(limit 5 s)" in err("wdl2") and "zbyva 8 s" in err("wdl2")
        and "Odeslany vysledky agent-side kontrol sluzeb." not in err("wdl2")
        and wdl2 is not None and wdl2["agent_run_ms"] == 50000,
    "dns: každý běh s payloadem se ptá bez -timeout - resolver, který odpoví za 2-5 s, je pomalý, ne mrtvý (dns_resolver_ok zůstává, co byl v 0.1.8)":
        len(ns_core) > 0 and set(ns_core) == {"example.com 127.0.0.1"},
    "update: the swap across filesystems is a rename - never a missing or short agent, no .bak, no .new (wupd1)":
        text("wupd1_rc.txt") == "rc=0 err=" and text("wupd1_cmp.txt") == "same" and upd_old > 0 and upd_new > 0
        and upd_samples >= 10 and len(upd_seen) > 0 and set(upd_seen) <= {str(upd_old), str(upd_new)}
        and text("wupd1_dir.txt") == "agent_openwrt.sh" and (text("wupd1_mode.txt") or "").startswith("-rwx"),
    "update: without room for the new file next to the old one nothing is written (wupd2)":
        (text("wupd2_rc.txt") or "").startswith("rc=1 err=space need=") and text("wupd2_cmp.txt") == "same"
        and text("wupd2_dir.txt") == "agent_openwrt.sh",
    "update: .new po přerušené výměně zmizí dřív, než se měří místo - jinak by na plném overlayi odmítal každou další aktualizaci (wupd2)":
        (text("wupd2_rc.txt") or "").startswith("rc=1 err=space") and text("wupd2_dir.txt") == "agent_openwrt.sh",
})
# --- W1-7: what a run costs, and the budget it must stay in ---
# (openwrt-stubs/run-in-container.sh: wbud0..wbud5)
#
# FORK_BUDGET holds one warm run of THIS harness - a verbose --dry-run with a
# canned 200, no cfg, the stub fixtures, the SMART cache fresh - to its forks,
# counted by the PID namespace's last-PID counter, so it is exact and the same
# on every host. Measured when wave 1 (W1-1..W1-7) was done: 195 in each of 9
# warm runs, back to back or 12 s apart; 0.1.8 before the wave: 510-515 in
# the same setup. The margin of 5 is one step of 4 - identical warm runs of
# 0.1.8 still alternated 511/515 here, and the audit saw 474/478 in 0.1.7;
# none was seen after the wave, but its cause was never pinned - plus the one
# extra fork a first warm run has shown in this wave (185 against 184 in the
# cron-like profile). So a change that adds a pipeline to the minute run
# fails here, or at the latest the one after it. Every change that saves forks
# lowers the budget in the same commit (plan: migration rule 1); raising it
# needs a reason in the commit, not a wider margin.
# FORK_SLACK makes that rule a check: a budget more than 9 forks above the
# measured run fails too (the margin of 5, plus one step of 4 in case the
# alternation ever lands below 195). Without it a budget raised "for room"
# would pass forever, and a saving would never be locked in.
#
# MAX_RSS_KB is the largest single process of such a run - the agent's shell
# or any child, ru_maxrss over the whole tree from wait4(). Measured
# 4,108-4,248 kB on arm64, the Wi-Fi awk (the shell itself is 2.7 MB).
# 6,144 kB is about 45 % above: the x86_64 runner of CI was not measured, and
# allocator and text size differ between the two. A change that holds a
# table or a tool output several MB big in one process fails. Below 2,048 kB
# the MEASUREMENT is broken (the shell alone is more), not the agent frugal -
# e.g. a busybox whose `time` stopped multiplying %M by the page size.
#
# SHELL_ANON_KB is the agent shell's own heap and stack (RssAnon, the largest
# of the 20 ms samples of wbud6): what a variable holding a whole tool output
# grows, and what the tree ceiling above cannot see under the Wi-Fi awk.
# Measured 488-504 kB on arm64 in this wave (0.1.8: 448-524 kB; an idle
# busybox sh is 128 kB). RssAnon leaves out the busybox text, the part
# that depends on the CPU, and both CI and this host are 64-bit, so the
# margin is for the allocator only: 768 kB, about 50 % above. A shell that
# keeps a few hundred kB of output in a variable fails. A sample can miss a
# spike shorter than 20 ms: this can let one through, never fail a good run.
# Below 256 kB the sampling is broken, not the shell small.
#
# PRIV_MAX_PAGES is what the warm runs leave in the private directory, in
# 4 kB pages - on a router that is tmpfs, so RAM, and a file of a few bytes
# still takes a whole page. Measured 26 pages (26 files, 4,117 B: the six
# Wi-Fi interfaces of the fixture have two files each); 0.1.8 left 24 (20
# files, one of them the 16.9 kB last-payload.json written by every run).
# The fixture is fixed, so the count is exact and has no margin: a new state
# file, or one that outgrows a page, raises it in its own commit, with the
# reason there. 0.1.11: 28 - uplink.ring (the counter snapshots the speedtest
# uplink is judged on) and uplink.cache (the verdict of a result not yet
# acknowledged), one page each.
FORK_BUDGET = 200
FORK_SLACK = 9
MAX_RSS_KB = 6144
SHELL_ANON_KB = 768
PRIV_MAX_PAGES = 28
def bud(name):
    """(forks or None, CPU ms by wait4, max RSS kB) of a run under `time`."""
    forks = text(f"{name}_forks.txt")
    try:
        u, s, m = (text(f"{name}_time.txt") or "").splitlines()[-1].split()
        cpu, rss = round((float(u) + float(s)) * 1000), int(m) // int(text("wbud_pagekb.txt"))
    except (IndexError, ValueError, TypeError, ZeroDivisionError):
        cpu = rss = None
    return (int(forks) if forks and forks.isdigit() else None), cpu, rss
wb = {n: maybe(f"wbud{n}") for n in "012345"}
bud1, bud2 = bud("wbud1"), bud("wbud2")
bud_forks = [b[0] for b in (bud1, bud2) if b[0] is not None]
bud_rss = [b[2] for b in (bud1, bud2)]
print(f"info  budget: warm forks {bud1[0]}, {bud2[0]} (budget {FORK_BUDGET}); max RSS {bud1[2]}, {bud2[2]} kB "
      f"(ceiling {MAX_RSS_KB}); CPU by time {bud1[1]}, {bud2[1]} ms; wbud1 reported by wbud2: "
      f"{(wb['2'] or {}).get('agent_prev_cpu_ms', 'MISSING')} ms")
try:
    shell_anon, shell_hwm, shell_samples = (int(v) for v in (text("wbud6_mem.txt") or "").split())
except ValueError:
    shell_anon = shell_hwm = shell_samples = None
priv = []
for line in (text("wbud_priv.txt") or "").splitlines():
    size, _, name = line.partition(" ")
    priv.append((int(size) if size.isdigit() else None, name))
# ceil(size / 4096): tmpfs gives an empty file no page, any other at least one.
priv_pages = sum(-(-s // 4096) for s, _ in priv if s is not None)
print(f"info  memory: shell RssAnon peak {shell_anon} kB (VmHWM {shell_hwm} kB, {shell_samples} samples, "
      f"ceiling {SHELL_ANON_KB}); private dir {len(priv)} files, {sum(s or 0 for s, _ in priv)} B, "
      f"{priv_pages} pages (budget {PRIV_MAX_PAGES}): {' '.join(n for _, n in priv)}")
def prev_cpu(p):
    return "MISSING" if p is None else p.get("agent_prev_cpu_ms", "MISSING")
checks.update({
    "cost: every payload run carries agent_prev_cpu_ms, and the first run of all has no previous run - null, not 0":
        all(prev_cpu(p) != "MISSING" for p in (d1, d, d2b, d3, d4, d5))
        and d1["agent_prev_cpu_ms"] is None and prev_cpu(wb["0"]) is None,
    "cost: the previous run's CPU is what `time` measured for it - user + system, children included, 10 ms steps (wbud1 -> wbud2)":
        isinstance(prev_cpu(wb["2"]), int) and bud1[1] is not None
        and prev_cpu(wb["2"]) > 0 and prev_cpu(wb["2"]) % 10 == 0
        # Below: ticks truncated per field on both sides, and the `rm` of the
        # lock that runs after the trap. Above: rounding only.
        and bud1[1] - 60 <= prev_cpu(wb["2"]) <= bud1[1] + 20
        and isinstance(d["agent_prev_cpu_ms"], int) and d["agent_prev_cpu_ms"] > 0,
    "cost: a run killed before its EXIT trap leaves null for the next report, not the run before it (wbud3, wbud4)":
        text("wbud3_runcpu.txt") == "0" and prev_cpu(wb["4"]) is None,
    "cost: the first report of a new version does not carry the old version's run (wbud5)":
        (text("wbud4_runcpu.txt") or "").isdigit() and prev_cpu(wb["5"]) is None,
    f"budget: a warm run of the harness makes at most {FORK_BUDGET} forks (wbud1, wbud2)":
        len(bud_forks) > 0 and max(bud_forks) <= FORK_BUDGET,
    f"budget: the fork budget is at most {FORK_SLACK} above the measured warm run, so a saving lowers it (wbud1, wbud2)":
        len(bud_forks) > 0 and FORK_BUDGET - max(bud_forks) <= FORK_SLACK,
    f"budget: no process of a warm run holds more than {MAX_RSS_KB} kB, and the measurement is alive (wbud1, wbud2)":
        all(r is not None and 2048 <= r <= MAX_RSS_KB for r in bud_rss),
    f"budget: the agent shell's heap and stack stay under {SHELL_ANON_KB} kB, sampled while it runs (wbud6)":
        shell_anon is not None and shell_samples >= 3 and 256 <= shell_anon <= SHELL_ANON_KB
        and isinstance(prev_cpu(maybe("wbud6")), int),
    f"budget: the warm runs leave at most {PRIV_MAX_PAGES} tmpfs pages in the private directory (wbud2)":
        len(priv) > 0 and all(s is not None for s, _ in priv) and priv_pages <= PRIV_MAX_PAGES,
})
# The one check on the agent's SOURCE, not its output: busybox 1.37 reads a
# backslash in the replacement text of sub()/gsub() the POSIX way ("\\\\" is
# one backslash), 1.36 - the image this harness runs - the old way. An escaper
# built on it passes every payload check here and prints raw quotes on a
# newer router, whose report the server then refuses whole.
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vps-agent", "agent_openwrt.sh"), encoding="utf-8") as _f:
    agent_src = _f.read()
awk_subs = re.findall(r'\bg?sub\(\s*/(?:\\.|[^/\\\n])*/\s*,\s*"((?:\\.|[^"\\\n])*)"', agent_src)
checks.update({
    "awk: žádné sub()/gsub() s obráceným lomítkem v náhradě - busybox 1.37+ ho čte jinak a uvozovky by šly do JSON syrové":
        len(awk_subs) >= 50 and [r for r in awk_subs if "\\" in r] == [],
})
# --- 0.1.10 ---------------------------------------------------------------
_wjs = text("wjs.txt")
try:
    _wjs_parsed = json.loads('"' + (_wjs or "") + '"')
except ValueError:
    _wjs_parsed = None
checks.update({
    "cost: a manual --dry-run neither takes the cron run's CPU and total nor writes its own (wdry)":
        text("wdry_cost.txt") == "1234\n5678" and text("wdry_lock.txt") == "no",
    "json: bk_js turns TAB and other control characters into spaces, so the string is valid JSON (wjs)":
        _wjs_parsed is not None and not any(ord(c) < 32 for c in _wjs_parsed)
        and '"' in _wjs_parsed and "\\" in _wjs_parsed,
})

# Checks written down before the collector that can pass them: the stubs
# already serve the real router, the Wi-Fi block of the agent is still the
# 0.1.6 one. A pending check does not fail the run, but one that PASSES does,
# so the list empties itself as the work lands and cannot go stale. It must be
# empty before a release: BK_E2E_STRICT=1 turns every pending check into a
# failure.
PENDING = set() if os.environ.get("BK_E2E_STRICT") == "1" else set()
unknown = PENDING - set(checks)
failed = [k for k, v in checks.items() if (k in PENDING) == bool(v)] + sorted(unknown)
for k, v in checks.items():
    if k in PENDING:
        print(("FAIL " if v else "todo "), k, "(passes now - take it off PENDING)" if v else "(pending)")
    else:
        print(("ok   " if v else "FAIL "), k)
for k in sorted(unknown):
    print("FAIL  PENDING names a check that does not exist:", k)
todo = len([k for k in PENDING if k in checks and not checks[k]])
print(f"{len(checks) - len(failed) - todo}/{len(checks) - todo} passed" + (f", {todo} pending" if todo else ""))
sys.exit(1 if failed else 0)

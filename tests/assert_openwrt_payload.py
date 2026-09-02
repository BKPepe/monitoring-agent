#!/usr/bin/env python3
"""Asserts on the two dry-run payloads produced by run_openwrt_e2e.sh.

Every expectation here matches the canned tool output in openwrt-stubs/bin;
a failing check means a parser in agent_openwrt.sh reads the wrong column,
fabricates a value, or emits invalid JSON."""
import json
import sys

out = sys.argv[1]
d1 = json.load(open(f"{out}/r1.json"))
d = json.load(open(f"{out}/r2.json"))
d3 = json.load(open(f"{out}/r3.json"))  # no "wan" interface at all
try:
    calls = open(f"{out}/hilink_calls.log").read().split()
except FileNotFoundError:
    calls = []
def hilink_calls(path):
    return sum(1 for c in calls if c.endswith(path))
wg = d["wireguard_peers"]
radios = {r["radio"]: r for r in d["wifi_radios"]}
checks = {
    "wireguard: the interface line is skipped, two peers remain": len(wg) == 2,
    "wireguard: public_key is the peer's key, not the private key": wg[0]["public_key"].startswith("PEERONEpubke"),
    "wireguard: handshake/rx/tx come from the right columns": (wg[0]["latest_handshake"], wg[0]["rx_bytes"], wg[0]["tx_bytes"]) == (1725000000, 12345, 67890),
    "wireguard: IPv6 endpoint without port and brackets": wg[1]["endpoint"] == "2001:db8::1",
    "mwan3: active gateway is the online interface": d["mwan3_active_gw"] == "wan",
    "mwan3: interface list online/offline": [(p["interface"], p["status"]) for p in d["mwan3_policies"]] == [("wan", "online"), ("wwan", "offline")],
    "sqm: dropped read after the word, ecn not measured": d["sqm_dropped"] == 12 and d["sqm_ecn"] is None,
    "service restarts counted from one logread": d["service_restarts"] == {"dnsmasq": 2, "uhttpd": 1},
    "log errors counted": d["log_errors_24h"] == 2,
    "wifi: enabled radio has channel, clients, ssid, power, noise": radios["wlan0"]["channel"] == 6 and radios["wlan0"]["clients"] == 2 and radios["wlan0"]["ssid"] == "Home" and radios["wlan0"]["tx_power"] == 20 and radios["wlan0"]["noise"] == -95,
    "wifi: disabled radio reports null, not channel 0 at 0 dBm": radios["wlan1"]["channel"] is None and radios["wlan1"]["tx_power"] is None and radios["wlan1"]["noise"] is None and radios["wlan1"]["ssid"] is None and radios["wlan1"]["clients"] == 0,
    "wifi_clients_count is the sum over radios": d["wifi_clients_count"] == 2,
    "firewall: accept/drop/reject sums and enabled from one ruleset": (d["fw_accepted"], d["fw_dropped"], d["fw_rejected"], d["firewall_enabled"]) == (200, 5, 3, True),
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
    "hilink: registration asked every run": hilink_calls("/api/monitoring/status") == 2,
    "hilink: SIM state and operator asked once, then served from the cache": hilink_calls("/api/pin/status") == 1 and hilink_calls("/api/net/current-plmn") == 1,
    "no interfaces at all: LTE stays unknown": d3["lte_up"] is None and d3["lte_connected"] is None,
    "link roles: the WAN device is reported, the LTE rate is measured on the second run": d["wan_l3_device"] == "eth0" and d1["net_lte"] is None and isinstance(d["net_lte"], (int, float)),
    "no interfaces at all: no WAN device, no LTE rate": d3["wan_l3_device"] is None and d3["net_lte"] is None,
    "version reported": isinstance(d.get("version"), str) and d["version"] != "",
}
failed = [k for k, v in checks.items() if not v]
for k, v in checks.items():
    print(("ok   " if v else "FAIL "), k)
print(f"{len(checks) - len(failed)}/{len(checks)} passed")
sys.exit(1 if failed else 0)

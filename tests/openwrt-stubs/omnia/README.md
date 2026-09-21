# The owner's Turris Omnia, as fixtures

Outputs captured on a real Turris Omnia (TurrisOS, kernel 6.6, 2026-09-16 to
2026-09-21) and served by the stubs in `../bin` and by `../mkroot.sh`. They
exist because the first version of several parsers was written against
invented output and was wrong about the real one.

**Identifiers are masked and stay masked.** MAC addresses are `02:00:00:00:..`
(locally administered), the SSIDs are replaced, the disk's serial number and
WWN are cut out. Never add an address, MAC, BSSID, serial number or WWN here,
and never a public IP address of a real line.

| File | Origin |
| --- | --- |
| `iwinfo_info.txt`, `iwinfo_assoclist.txt` | real: `iwinfo phy0-ap0 info` / `assoclist` (MT7915E, 5 GHz, HE80, four clients) |
| `hostapd_all_sta.txt` | real: `hostapd_cli -i phy0-ap0 all_sta`, two captures merged per station in hostapd's order |
| `survey_1.txt`, `survey_2.txt` | the in-use block is real; sample 2 is sample 1 plus 12,000 ms of active time with the real ratios (+420 busy, +208 transmit, +68 BSS receive, so busy 3.5 %, foreign 1.2 %). The leading `[in use]` block on 2437 MHz is a decoy with absurd counters, the trailing 5200 MHz block a neighbour entry |
| `survey_wlan0_1.txt`, `survey_wlan0_2.txt` | synthetic: +60,000 ms of active time within the harness's 11 s, an impossible delta |
| `survey_wlan7_1.txt`, `survey_wlan7_2.txt` | synthetic: a channel that was busy for 75 % of the radio's lifetime and is 10 % busy (5 % foreign) over the last 12,000 ms. On phy0-ap0 the lifetime average and the delta agree to one decimal (3.4955 % vs 3.5 %), so only this pair tells a delta reading from a reading of the absolute counters |
| `caps.txt` | **synthesized** (`htmodelist` on line 1, `freqlist` below), not captured yet |
| `iwinfo_phy3_info.txt` | real: the second radio, a USB adapter on 2.4 GHz whose driver reports `Noise: unknown` |
| `hostapd_phy3_all_sta.txt` | real (flags only): six HT stations, three with `[MFP]`, none with an operating-class list |
| `iwinfo_phy3_assoclist.txt` | **synthesized** from the two files above (six stations, unknown noise); no capture exists |
| `smartctl_sda.gron` | real: `smartctl -j -a /dev/sda` (Kingston SUV500MS120G behind SAT) converted to the flat `--json=g` form; `serial_number` and `wwn` removed, as `-q noserial` does |
| `softnet_stat.txt`, `nf_conntrack.txt` | real: `/proc/net/softnet_stat` (15 hex columns, column 13 is the CPU index) and `/proc/net/stat/nf_conntrack` (880 entries, no drops) |
| `nf_conntrack_busy.txt` | synthetic, same shape and header as the real capture: 2 + 1 insert_failed, 1 + 0 drop and `0x12` + 0 early_drop over the two CPUs, with a non-zero `insert` (column 9) and `icmp_error` (column 13) beside them. The real capture is all zeros in columns 10-12, so only this copy can tell a hex reading from a decimal one (18 vs 12) and a column read one to the side |
| `nf_conntrack_other.txt` | synthetic: a kernel whose counters come in another order and which has no `insert_failed` column at all (the 3.x layout with `searched` / `delete_list`). Columns 10-12 are full of hex, so a parser that skips the header instead of reading it sends three numbers nobody measured |
| `hwmon_names.txt` | real: `hwmonN` to name; the index changes between boots, the name does not |
| `ubus_network_device_status.json` | real, byte for byte: `ubus call network.device status` with ubus's own formatting (tabs, an empty array over three lines, `"speed": "2500F"`) |
| `ubus_network_device_status_lan1_only.json` | the same capture with the two gigabit cables out: `lan0` and `lan4` lose their `"speed"` line and their `"carrier"` is false. Four lines of difference, so that the fastest port LINKED (lan1 at 100) and what every port SUPPORTS (1000) part company - on the real capture both answer 1000 and a capability read off a negotiated rate looks right. Served by `BK_STUB_UBUS_DEV=lan1only` |

Facts that are not files: the WAN is PPPoE over VLAN 848 over `eth2` (SFP at
2500 Mbit/s; `BK_STUB_WAN=pppoe` in `../bin/ubus` and `../jshn.sh`), the LAN
ports are DSA ports behind the one conduit `eth1` at 1000, `/sys/block` has
`loop0-7`, `mtdblock0-2` and `sda` and **no `mmcblk0`**. `../mkroot.sh` builds
all of that; its comments name every value that is not the router's own (the
raised port counters of `eth2`, the synthetic disks, the temperatures).

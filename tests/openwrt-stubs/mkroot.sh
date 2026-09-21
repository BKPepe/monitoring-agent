#!/bin/sh
# mkroot.sh DIR [emmc] - the fake /sys and /proc the agent reads through its
# dry-run seam (STATUS_TEST_ROOT=DIR). What the owner's Turris Omnia really
# has is copied from the captures in omnia/ (see omnia/README.md): the block
# list (loop0-7, mtdblock0-2, sda - and NO mmcblk0), PPPoE over VLAN 848 over
# eth2, the DSA ports behind eth1, the hwmon names, softnet and conntrack.
# Around that stand synthetic devices, one per parser branch that the Omnia
# cannot show. "emmc" adds what a router with eMMC has, and sde, the disk
# whose smartctl ignores TERM.
#
# Decoy files (wwid, vpd_pg80, serial, cid) hold the word SERIALLEAK: the
# agent must never open an identifier, and the test greps for that word.
set -e
R="$1"; VARIANT="$2"
[ -n "$R" ] || { echo "usage: mkroot.sh DIR [emmc]" >&2; exit 1; }
rm -rf "$R"
S="$R/sys"; P="$R/proc"
mkdir -p "$S/block" "$S/class/net" "$S/class/hwmon" "$P/net/stat"

# disk NAME SECTORS ROTATIONAL REMOVABLE DEVICE_DIR [PARTITION:SECTORS ...]
# DEVICE_DIR (below sys/devices) is what /sys/block/NAME/device points to;
# the block directory sits in DEVICE_DIR/block/NAME as in a real sysfs, so
# `readlink -f` shows the transport (ata1, usb4/4-1, nvme/nvme0, mmc_host).
disk() {
    _n="$1"; _dev="$S/devices/$5"; _b="$_dev/block/$_n"
    mkdir -p "$_b/queue"
    echo "$2" > "$_b/size"; echo "$3" > "$_b/queue/rotational"; echo "$4" > "$_b/removable"
    ln -s ../.. "$_b/device"
    ln -s "../devices/$5/block/$_n" "$S/block/$_n"
    shift 5
    for _p; do
        mkdir -p "$_b/${_p%%:*}"
        echo 1 > "$_b/${_p%%:*}/partition"; echo "${_p##*:}" > "$_b/${_p%%:*}/size"
    done
}
scsi_ids() { # DEVICE_DIR MODEL VENDOR - sysfs cuts the model to 16 characters
    echo "$2" > "$S/devices/$1/model"; echo "$3" > "$S/devices/$1/vendor"
    echo "DECOY-WWID-t10.ATA-SERIALLEAK" > "$S/devices/$1/wwid"
    echo "DECOY-VPD80-SERIALLEAK" > "$S/devices/$1/vpd_pg80"
}
SOC=platform/soc/soc:internal-regs

# --- the Omnia's real block list -----------------------------------------
_d="$SOC/f10a8000.sata/ata1/host0/target0:0:0/0:0:0:0"
disk sda 234441648 0 0 "$_d" sda1:234439600
scsi_ids "$_d" "KINGSTON SUV500M" "ATA     "
for _i in 0 1 2 3 4 5 6 7; do
    mkdir -p "$S/devices/virtual/block/loop$_i"; echo 0 > "$S/devices/virtual/block/loop$_i/size"
    ln -s "../devices/virtual/block/loop$_i" "$S/block/loop$_i"
done
# Raw NOR flash: it HAS a device link (so "has a device" is not the filter),
# no SMART and no user data.
for _i in 0 1 2; do
    mkdir -p "$S/devices/$SOC/f1010600.spi/mtd/mtd$_i/mtdblock$_i"
    echo 16384 > "$S/devices/$SOC/f1010600.spi/mtd/mtd$_i/mtdblock$_i/size"
    ln -s ../../mtd$_i "$S/devices/$SOC/f1010600.spi/mtd/mtd$_i/mtdblock$_i/device"
    ln -s "../devices/$SOC/f1010600.spi/mtd/mtd$_i/mtdblock$_i" "$S/block/mtdblock$_i"
done

# --- synthetic disks ------------------------------------------------------
# sdb: USB hard disk, asleep until its diskstats move (see proc/diskstats.2).
_d="$SOC/f10f8000.usb3/usb4/4-1/4-1:1.0/host2/target2:0:0/2:0:0:0"
disk sdb 1953525168 1 0 "$_d" sdb1:1953523120
scsi_ids "$_d" "Elements 25A2   " "WD      "
# sdc: USB stick behind a bridge smartctl does not know.
_d="$SOC/f10f8000.usb3/usb4/4-2/4-2:1.0/host3/target3:0:0/3:0:0:0"
disk sdc 60437492 0 1 "$_d" sdc1:60435444
scsi_ids "$_d" "Flash Disk      " "Generic "
# sdd: a second SATA SSD the drive database does not know.
_d="$SOC/f10a8000.sata/ata2/host1/target1:0:0/1:0:0:0"
disk sdd 234441648 0 0 "$_d" sdd1:234439600
scsi_ids "$_d" "KINGSTON SUV500M" "ATA     "
# nvme0n1: `device` is the controller, which carries model and serial.
_d="platform/soc/soc:pcie/pci0000:00/0000:00:02.0/0000:02:00.0/nvme/nvme0"
mkdir -p "$S/devices/$_d/nvme0n1/queue" "$S/devices/$_d/nvme0n1/nvme0n1p1"
echo 500118192 > "$S/devices/$_d/nvme0n1/size"; echo 0 > "$S/devices/$_d/nvme0n1/queue/rotational"
echo 0 > "$S/devices/$_d/nvme0n1/removable"
echo 1 > "$S/devices/$_d/nvme0n1/nvme0n1p1/partition"; echo 500116144 > "$S/devices/$_d/nvme0n1/nvme0n1p1/size"
ln -s .. "$S/devices/$_d/nvme0n1/device"
echo "Generic NVMe 256GB" > "$S/devices/$_d/model"; echo "DECOY-NVME-SERIALLEAK" > "$S/devices/$_d/serial"
ln -s "../devices/$_d/nvme0n1" "$S/block/nvme0n1"
# zram0: compressed RAM, not a disk.
mkdir -p "$S/devices/virtual/block/zram0"; echo 1048576 > "$S/devices/virtual/block/zram0/size"
ln -s ../devices/virtual/block/zram0 "$S/block/zram0"

# --- proc -------------------------------------------------------------------
# diskstats: field 6 = sectors read, field 10 = sectors written. diskstats.2
# is the same list a moment later: sda and sdb moved (the USB disk woke up),
# nothing else did. The harness copies it over diskstats before its 2nd run.
ds() { # SUFFIX SDA_READ SDA_WRITTEN SDB_READ SDB_WRITTEN
    {
        printf '   8       0 sda 1000 0 %s 0 2000 0 %s 0 0 0 0\n' "$2" "$3"
        printf '   8       1 sda1 900 0 40000 0 1900 0 870000 0 0 0 0\n'
        printf '   8      16 sdb 300 0 %s 0 100 0 %s 0 0 0 0\n' "$4" "$5"
        printf '   8      17 sdb1 290 0 23000 0 95 0 7900 0 0 0 0\n'
        printf '   8      32 sdc 50 0 4000 0 0 0 0 0 0 0 0\n'
        printf '   8      48 sdd 700 0 30000 0 900 0 410000 0 0 0 0\n'
        printf ' 259       0 nvme0n1 5000 0 250000 0 7000 0 3300000 0 0 0 0\n'
        printf '  31       0 mtdblock0 1 0 8 0 0 0 0 0 0 0 0\n'
        printf ' 253       0 zram0 40 0 320 0 60 0 480 0 0 0 0\n'
        [ "$VARIANT" = "emmc" ] && printf ' 179       0 mmcblk0 800 0 64000 0 1200 0 96000 0 0 0 0\n   8      64 sde 10 0 800 0 10 0 800 0 0 0 0\n'
        :
    } > "$P/diskstats$1"
}
ds "" 50000 880000 24000 8000
ds .2 50640 883200 24512 8064
# stat / stat.2: two cores, core 0 drowning in softirq between the two (the
# busiest core is 98.2 % while the aggregate says about half).
cat > "$P/stat" <<'M'
cpu  1000 0 500 8000 100 50 350 0 0 0
cpu0 600 0 300 3500 50 40 310 0 0 0
cpu1 400 0 200 4500 50 10 40 0 0 0
intr 12345 1 2 3
ctxt 1
M
cat > "$P/stat.2" <<'M'
cpu  1100 0 700 11000 100 60 3340 0 0 0
cpu0 650 0 400 3600 50 50 5550 0 0 0
cpu1 450 0 300 9400 50 10 90 0 0 0
intr 22345 1 2 3
ctxt 2
M
echo "1000.00 1500.00" > "$P/uptime"
HERE="$(cd "$(dirname "$0")" && pwd)"
cp "$HERE/omnia/softnet_stat.txt" "$P/net/softnet_stat"          # real: 15 hex columns, col 13 = CPU index
cp "$HERE/omnia/nf_conntrack.txt" "$P/net/stat/nf_conntrack"     # real: 880 entries, no drops
# The same file a busy minute later: hexadecimal 3 insert_failed, 1 drop,
# 0x12 = 18 early_drop over the two CPUs, and a non-zero `insert` and
# `icmp_error` next to them so a column off by one cannot pass. The harness
# copies it over nf_conntrack before its second run.
cp "$HERE/omnia/nf_conntrack_busy.txt" "$P/net/stat/nf_conntrack.2"
# And a kernel that prints its counters in another order: no insert_failed at
# all, so columns 10-12 are drop, early_drop and icmp_error. Nothing may be
# read out of it (the harness swaps it in for the walk runs).
cp "$HERE/omnia/nf_conntrack_other.txt" "$P/net/stat/nf_conntrack.other"

# --- eMMC variant -----------------------------------------------------------
if [ "$VARIANT" = "emmc" ]; then
    _d="$SOC/f10d8000.sdhci/mmc_host/mmc0/mmc0:0001"
    disk mmcblk0 15269888 0 0 "$_d" mmcblk0p1:524288 mmcblk0p2:14743552
    echo "8GME4R" > "$S/devices/$_d/name"; echo "MMC" > "$S/devices/$_d/type"
    echo "0x02 0x01" > "$S/devices/$_d/life_time"; echo "0x01" > "$S/devices/$_d/pre_eol_info"
    echo "DECOY-CID-SERIALLEAK" > "$S/devices/$_d/cid"; echo "0xSERIALLEAK" > "$S/devices/$_d/serial"
    # Boot and RPMB areas show up in /sys/block next to the disk; they are not disks.
    for _x in mmcblk0boot0 mmcblk0rpmb; do
        mkdir -p "$S/devices/$_d/block/$_x"; echo 8192 > "$S/devices/$_d/block/$_x/size"
        ln -s ../.. "$S/devices/$_d/block/$_x/device"
        ln -s "../devices/$_d/block/$_x" "$S/block/$_x"
    done
    # sde: SATA, not rotational - so it is due for SMART at once.
    _d="$SOC/f10a8000.sata/ata3/host4/target4:0:0/4:0:0:0"
    disk sde 234441648 0 0 "$_d" sde1:234439600
    scsi_ids "$_d" "SLOW DISK       " "ATA     "
fi

# --- sys/class/net ------------------------------------------------------------
# netdev NAME SPEED|- PHYSICAL(1|0) [LOWER ...] ; statistics default to 0.
# A physical netdev (a port, a DSA user port) has a `device` link; a virtual
# one (vlan, ppp, bridge) has none - that is how the WAN walk tells them apart.
netdev() {
    _n="$S/class/net/$1"; mkdir -p "$_n/statistics" "$_n/queues/rx-0"
    [ "$2" = "-" ] || echo "$2" > "$_n/speed"
    [ "$3" = 1 ] && { mkdir -p "$S/devices/$SOC/net-$1"; ln -s "../../../devices/$SOC/net-$1" "$_n/device"; }
    for _c in rx_bytes tx_bytes rx_packets tx_packets rx_errors tx_errors rx_dropped tx_dropped; do echo 0 > "$_n/statistics/$_c"; done
    echo 0 > "$_n/carrier_down_count"; echo 0 > "$_n/threaded"; echo 0 > "$_n/queues/rx-0/rps_cpus"
    _name="$1"; shift 3
    for _l; do ln -s "../$_l" "$_n/lower_$_l"; mkdir -p "$S/class/net/$_l"; ln -s "../$_name" "$S/class/net/$_l/upper_$_name"; done
}
stat_set() { echo "$3" > "$S/class/net/$1/statistics/$2"; }
# The owner's WAN: pppoe-wan -> eth2.848 -> eth2 (SFP at 2500). Byte counters
# are the real ones of the capture.
netdev eth2 2500 1
stat_set eth2 rx_bytes 40558104195; stat_set eth2 tx_bytes 2765975303
# Packet steering on the WAN port: mvneta has several RX queues and the init
# script fills them ALL, so the runtime answer is "any queue has a bit set",
# never "rx-0 alone". rx-0 carries 2 here and the other two are empty, which a
# parser that reads only the first queue and a parser that demands every queue
# both get wrong.
mkdir -p "$S/class/net/eth2/queues/rx-1" "$S/class/net/eth2/queues/rx-2"
echo 2 > "$S/class/net/eth2/queues/rx-0/rps_cpus"
echo 0 > "$S/class/net/eth2/queues/rx-1/rps_cpus"
echo 0 > "$S/class/net/eth2/queues/rx-2/rps_cpus"
# The real port counters are all 0, which no test could tell from "not read":
# these four are raised on purpose. The VLAN's 174 drops ARE real - the VLAN
# layer drops frames of its own, and they must never be reported as the port's.
stat_set eth2 rx_errors 3; stat_set eth2 tx_errors 1; stat_set eth2 rx_dropped 120; stat_set eth2 tx_dropped 2
# The link has flapped four times since boot. It sits on the PORT; the ppp and
# VLAN netdevs above it keep their 0, so a counter read off the l3 device is
# visible as a 0 nobody measured.
echo 4 > "$S/class/net/eth2/carrier_down_count"
netdev eth2.848 2500 0 eth2
stat_set eth2.848 rx_bytes 40038334341; stat_set eth2.848 tx_bytes 2716995797; stat_set eth2.848 rx_dropped 174
netdev pppoe-wan - 0 eth2.848
stat_set pppoe-wan rx_bytes 39807266851; stat_set pppoe-wan tx_bytes 2447601191
# ppp has no link settings: reading `speed` fails with EINVAL. A directory in
# its place makes `read` fail the same way.
mkdir "$S/class/net/pppoe-wan/speed"
# LAN: DSA user ports behind the one conduit eth1 (1000). lan1 talks to a
# 100 Mbit device, lan2 has no carrier (-1).
netdev eth1 1000 1
netdev lan0 1000 1; netdev lan1 100 1; netdev lan2 -1 1
netdev br-lan 1000 0 lan0 lan1 lan2
# eth3 is the HiLink LTE stick (150H in ubus): never a LAN port, never the WAN walk.
netdev eth3 150 1
# eth0 does not exist on the Omnia. It is the plain DHCP WAN port of the
# default stub answers (BK_STUB_WAN unset), so that case has a port as well.
netdev eth0 1000 1

# One netdev per branch of the WAN walk (WAN 3.1.1), each reached by its own
# BK_STUB_WAN value. They are synthetic: the Omnia has one WAN line and can
# show one branch at a time.
#   br-wan   a bridge over the SINGLE port eth2: the walk has to descend
#   br-wan2  a bridge over TWO ports - the kernel answers with the fastest
#            (2500), but there is no single port to charge counters to
#   ppp0     a lone ppp netdev: no link settings, nothing below it
#   wan      a DSA user port whose carrier is down (-1) above the conduit
#            eth1 at 1000. -1 is an ANSWER, so the 1000 below must not leak
netdev eth4 1000 1
netdev br-wan 2500 0 eth2
netdev br-wan2 2500 0 eth2 eth4
netdev ppp0 - 0
mkdir "$S/class/net/ppp0/speed"
netdev wan -1 1 eth1
stat_set wan rx_errors 9; stat_set wan rx_dropped 11
echo 7 > "$S/class/net/wan/carrier_down_count"
# A port whose RX queues the kernel does not expose (no RPS on this driver):
# steering is UNKNOWN there, which is not the same answer as "switched off".
rm -rf "$S/class/net/wan/queues"

# --- sys/class/hwmon: the real names, in the real order (indexes change
# between boots, names do not). Temperatures are synthetic. ------------------
_i=0
while read -r _path _hw; do
    mkdir -p "$S/class/hwmon/hwmon$_i"; echo "$_hw" > "$S/class/hwmon/hwmon$_i/name"
    case "$_hw" in
        f10e4078.thermal) _t=58000 ;; mt7915_phy0) _t=62000 ;; sfp) _t=49000 ;; *) _t=$((45000 + _i * 500)) ;;
    esac
    echo "$_t" > "$S/class/hwmon/hwmon$_i/temp1_input"
    _i=$((_i + 1))
done < "$HERE/omnia/hwmon_names.txt"
echo "$R"

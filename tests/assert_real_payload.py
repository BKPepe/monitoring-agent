#!/usr/bin/env python3
"""Asserts on the plain dry runs in real images and on a real router.

    assert_real_payload.py PROFILE DIR [--single] [--agent FILE]
    assert_real_payload.py selftest     the NF_STAT rules on their own samples

    openwrt-24.10, openwrt-master   DIR/<ver>_r{1,2}.{json,err,rc}  run_openwrt_real.sh
    ubuntu, alpine, rocky           DIR/<distro>_{sh,py}{1,2}.*     run_linux_distros.sh
    hw                              DIR/r{1,2}.*                    hw_smoke.sh

--single: hw only, one run (hw_smoke.sh --interval 0 or --coexist); the
first-run checks are skipped and the delta keys may be null.
--agent: the agent file the run used (its AGENT_VERSION is expected);
default the one of this checkout.

Per run: exit 0, stdout is exactly one JSON object without a duplicate key,
the right agent_type and version, no string "null" anywhere, and stderr holds
nothing but the agent's own log lines without an error marker (exceptions:
real/stderr_allow.txt). Then r1 must be honest (no delta yet: null) and r2
must measure the CORE set (values checked where the image fixes them, types
where they vary). In the images, r2 must also measure every other key unless
NULL_OK or VARIES names it, and boot.sh must have brought every service up.
hw keeps the CORE set only: what a real router measures is its own. OpenWrt
and hw: the conntrack counters follow what the target says of NF_STAT.

Python 3.9: the macOS host python runs it for hw_smoke.sh.
"""
import contextlib
import fnmatch
import io
import json
import os
import re
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
AGENTS = {
    "openwrt": os.path.join(HERE, "..", "vps-agent", "agent_openwrt.sh"),
    "bash": os.path.join(HERE, "..", "vps-agent", "agent.sh"),
    "python": os.path.join(HERE, "..", "vps-agent", "agent.py"),
}
ALLOW_FILE = os.path.join(HERE, "real", "stderr_allow.txt")

# The log format of all three agents: "YYYY-MM-DD HH:MM:SS - message".
LOG_LINE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} - ")
# What an error looks like: the agents' own (CHYBA, VAROVANI/VAROVÁNÍ), a
# Python traceback, and raw tool stderr that leaked past a missing 2>/dev/null
# into a log line.
MARKERS = (
    "CHYBA", "VAROV", "Traceback", "not found", "syntax error", "unexpected",
    "No such file", "Permission denied", "Operation not permitted", "can't",
    "cannot", "failed", "Failed",
)

# Every top-level key of a second run in an image (r2, sh2, py2) must be
# measured: not null, [], {} or "". The exceptions are (scopes, key glob,
# reason); a scope is openwrt-24.10, openwrt-master or <distro>/<sh|py>, and
# scopes holds space-separated globs of them.
#
# NULL_OK: what the image or boot.sh does not give the agent, and the run
# shows it (no modem, no package, an empty bridge). A NULL_OK key that is
# measured fails as stale: remove it with the change that made it measurable.
# A CORE key here is a gap in the CORE set, stale when its CORE check passes.
NULL_OK = [
    ("openwrt-*", "lte_*", "no modem: no uqmi, HiLink or LTE netdev"),
    ("openwrt-*", "net_lte", "no modem"),
    ("openwrt-*", "sqm_*", "no SQM package"),
    ("openwrt-*", "mwan3_*", "no mwan3"),
    ("openwrt-*", "wireguard_peers", "no wg"),
    ("openwrt-*", "tailscale_*", "no tailscale"),
    ("openwrt-*", "zerotier_networks", "no zerotier"),
    ("openwrt-*", "ups_*", "no upsc"),
    ("openwrt-*", "wifi_*", "no radio"),
    ("openwrt-*", "lan_ports", "br-lan is an empty bridge"),
    ("openwrt-*", "wan_link_dev", "eth0 is a veth with no port below it"),
    ("openwrt-*", "wan_carrier_down_count", "read off wan_link_dev"),
    ("openwrt-*", "wan_[rt]x_errors", "read off wan_link_dev"),
    ("openwrt-*", "wan_[rt]x_dropped", "read off wan_link_dev"),
    ("openwrt-*", "wan_ipv6", "docker's default network has no IPv6"),
    ("openwrt-*", "wan_last_reconnect", "the WAN does not reconnect between the runs"),
    ("openwrt-*", "speedtests", "no speedtest result on disk"),
    ("openwrt-*", "btrfs_errors", "no btrfs tool"),
    ("openwrt-*", "inode_usage", "the image's busybox df has no -i"),
    ("openwrt-*", "dns_queries", "dnsmasq never writes /tmp/dnsmasq.stats, the only source"),
    ("openwrt-*", "dns_cache_*", "dnsmasq never writes /tmp/dnsmasq.stats, the only source"),
    ("openwrt-*", "fw_rejected", "fw4's default reject rules carry no counter"),
    ("openwrt-*", "model", "no /tmp/sysinfo (preinit never ran) and no device tree on x86"),
    ("openwrt-*", "board_name", "no /tmp/sysinfo (preinit never ran) and no device tree on x86"),
    ("openwrt-24.10", "upgradable_packages", "no package lists: opkg update never ran"),
    ("*/*", "tailscale_*", "no tailscale"),
    ("*/*", "zerotier_networks", "no zerotier"),
    ("*/*", "ups_*", "no upsc"),
    ("*/*", "teamspeak_servers", "no TeamSpeak server"),
    ("*/*", "ts3_process", "no TeamSpeak server"),
    ("*/*", "ports", "nothing listens in the container"),
    ("*/*", "discovered_services", "no service runs in the container"),
    ("*/*", "virtualization", "no systemd-detect-virt in the image"),
    ("alpine/* rocky/*", "reboot_required", "not Debian: /var/run/reboot-required is Debian's convention"),
    ("alpine/*", "timezone", "no /etc/timezone and no /etc/localtime link"),
    ("ubuntu/sh rocky/sh", "dns_latency_ms", "no nslookup in the image"),
    ("alpine/sh", "processes", "busybox ps has no -o %cpu, so agent.sh's `ps -eo pid=,ppid=,stat=,%cpu=,rss=,comm=` "
     "fails silently and it sends [] - not an honest null (open finding: fix in agent.sh)"),
    ("alpine/sh", "zombie_count", "the same failed ps call"),
    ("alpine/sh", "top_cpu_processes", "the same failed ps call"),
    ("alpine/sh", "top_ram_processes", "the same failed ps call"),
]
# VARIES: what depends on the runner (its network, kernel, hardware, DMI) or
# on timing, so CI and a laptop differ. Either way passes, with no stale
# check; golden.py still checks the type.
VARIES = [
    ("openwrt-*", "temperature", "the runner's thermal zones"),
    ("openwrt-*", "disk_devices", "the runner's disks: the agent reads sd*, nvme*, mmcblk*, and Docker Desktop has vda"),
    ("openwrt-*", "disk_io_write", "the runner's disks, as disk_devices"),
    ("openwrt-*", "dns_latency_ms", "the runner's resolver"),
    ("openwrt-*", "wan_latency_ms", "ICMP from the runner"),
    ("openwrt-*", "log_errors_recent", "what the services log in the window"),
    ("openwrt-*", "log_warnings_24h", "what the services log in the window"),
    ("openwrt-*", "top_io_processes", "which processes wrote between the runs"),
    ("openwrt-master", "upgradable_packages", "whatever index the snapshot ships"),
    ("*/*", "temperature", "the runner's thermal zones"),
    ("*/*", "cloud_provider", "the runner's DMI: none on Docker Desktop, Azure on GitHub's runner"),
    ("*/py", "top_cpu_processes", "the processes that used CPU in agent.py's short sample"),
    ("alpine/sh */py", "dns_latency_ms", "the runner's resolver"),
]

# The only source of the three conntrack event counters. A kernel has it only
# with CONFIG_NF_CONNTRACK_PROCFS and nf_conntrack loaded: OpenWrt's kernels
# and Docker Desktop's do, GitHub's runner kernel does not, nor would a router
# without kmod-nf-conntrack. The harness asks the target itself
# (<ver>_nf_stat.txt, hw: nf_stat.txt, "present" or "absent: <reason>").
# Present: the counters are measured like every key, and any stderr line
# naming the file fails. Absent: they must be null in every run - a number
# would be invented.
NF_STAT = "/proc/net/stat/nf_conntrack"
NF_STAT_KEYS = ("conntrack_insert_failed", "conntrack_drop", "conntrack_early_drop")
# Known gap: agent_openwrt.sh 0.1.12 reads the file with `done < FILE
# 2>/dev/null`; the < is opened before the 2> applies, so a missing file
# prints this line. It passes only when the file is absent and the payload is
# one of these versions: 0.1.13 must not print it.
NF_STAT_GAP_VERSIONS = ("0.1.12",)
NF_STAT_GAP = re.compile(r"^(\./)?agent_openwrt\.sh: line \d+: can't open /proc/net/stat/nf_conntrack: no such file$")


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def measured(v):
    return v is not None and not (isinstance(v, (str, list, dict)) and len(v) == 0)


class P:
    """A predicate that can say what it wants."""

    def __init__(self, desc, fn):
        self.desc = desc
        self.fn = fn

    def __call__(self, v):
        return self.fn(v)


NUM = P("a number", is_num)
STR = P("a non-empty string", lambda v: isinstance(v, str) and v != "")
LIST = P("a non-empty list", lambda v: isinstance(v, list) and len(v) > 0)
BOOL_OR_NULL = P("true, false or null", lambda v: v is None or isinstance(v, bool))
POSITIVE = P("a number > 0", lambda v: is_num(v) and v > 0)


def eq(want):
    return P("== " + json.dumps(want), lambda v: v == want and type(v) is type(want))


def starts(prefix):
    return P("starting with " + json.dumps(prefix), lambda v: isinstance(v, str) and v.startswith(prefix))


def one_of(*wanted):
    return P("one of " + ", ".join(json.dumps(w) for w in wanted), lambda v: v in wanted)


def pkg_manager(*names):
    return P("an object whose pkg_manager is " + " or ".join(names),
             lambda v: isinstance(v, dict) and v.get("pkg_manager") in names)


NUMS = ("cpu", "ram", "ram_total_mb", "hdd", "load1", "uptime", "boot_time")
OWRT_DELTA = ("cpu", "cpu_cores", "net")
LINUX_DELTA = ("cpu", "net")


def owrt_core(profile):
    core = {k: NUM for k in NUMS + ("cpu_cores", "agent_time", "agent_run_ms")}
    core.update({
        "agent_type": eq("openwrt"),
        "hostname": STR, "kernel": STR,
        "installed_packages": POSITIVE,
        "interfaces": LIST, "filesystems": LIST,
        "dns_resolver_ok": BOOL_OR_NULL, "wan_internet": BOOL_OR_NULL,
    })
    if profile == "hw":
        # A real router: its own WAN, LAN and services, so types, not values.
        core.update({
            "os": STR, "model": STR, "board_name": STR,
            "agent_tools": pkg_manager("opkg", "apk"),
            "wan_up": BOOL_OR_NULL, "firewall_enabled": BOOL_OR_NULL,
            "log_lines_state": one_of("on", "off_router", "off_monitor"),
        })
        return core
    ver = profile.split("-", 1)[1]
    core.update({
        "os": starts("OpenWrt 24.10.8") if ver == "24.10" else starts("OpenWrt SNAPSHOT"),
        "agent_tools": pkg_manager("opkg" if ver == "24.10" else "apk"),
        # What boot.sh configured.
        "wan_up": eq(True), "wan_proto": eq("static"), "wan_l3_device": eq("eth0"),
        "wan_ipv4": STR, "wan_gateway": STR,
        "lan_subnet": eq("10.231.0.1/24"),
        "firewall_enabled": eq(True), "fw_accepted": NUM,
        "dns_engine": eq("Dnsmasq"),
        "log_lines_state": eq("on"),
    })
    return core


def linux_core(kind):
    core = {k: NUM for k in NUMS + ("net", "fork_rate", "zombie_count")}
    core.update({
        "agent_type": eq("bash" if kind == "sh" else "python"),
        "os": STR, "hostname": STR, "kernel": STR,
        "processes": LIST,
    })
    if kind == "sh":
        # agent.py has no filesystem list.
        core["filesystems"] = LIST
    return core


def agent_version(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'^AGENT_VERSION ?= ?"([^"]+)"', line)
            if m:
                return m.group(1)
    return None


def no_dups(pairs):
    seen = {}
    for k, v in pairs:
        if k in seen:
            raise ValueError("duplicate key " + repr(k))
        seen[k] = v
    return seen


def string_nulls(v, path=""):
    if v == "null":
        yield path or "(top)"
    elif isinstance(v, dict):
        for k, x in v.items():
            yield from string_nulls(x, path + "." + k if path else k)
    elif isinstance(v, list):
        for i, x in enumerate(v):
            yield from string_nulls(x, "%s[%d]" % (path, i))


def load_allow(profile):
    entries = []
    if not os.path.exists(ALLOW_FILE):
        return entries
    with open(ALLOW_FILE, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            body = line.split("  #", 1)[0].strip()
            scope, _, rx = body.partition(" ")
            if fnmatch.fnmatchcase(profile, scope):
                entries.append({"where": "%s:%d" % (os.path.basename(ALLOW_FILE), n),
                                "rx": re.compile(rx.strip()), "hits": 0})
    return entries


class Checker:
    def __init__(self):
        self.failed = []

    def check(self, label, cond):
        print(("ok   " if cond else "FAIL "), label)
        if not cond:
            self.failed.append(label)
        return cond

    def info(self, label):
        print("info ", label)


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def check_run(c, tag, base, agent_type, version, allow, nf_stat=None):
    """The per-run checks; returns the payload or None. NF_STAT: what the
    target said of NF_STAT (OpenWrt and hw; "" when it said nothing)."""
    rc = read(base + ".rc")
    c.check("%s: exit 0 (got %s)" % (tag, (rc or "no .rc file").strip()), rc is not None and rc.strip() == "0")
    text = read(base + ".json")
    payload = None
    try:
        payload = json.loads(text if text is not None else "", object_pairs_hook=no_dups)
    except ValueError as e:
        c.check("%s: stdout is one JSON object (%s)" % (tag, e), False)
    if payload is not None and not c.check("%s: stdout is one JSON object" % tag, isinstance(payload, dict)):
        payload = None
    if payload is not None:
        c.check("%s: agent_type %r" % (tag, agent_type), payload.get("agent_type") == agent_type)
        c.check("%s: version %s (got %r)" % (tag, version, payload.get("version")), payload.get("version") == version)
        bad = list(string_nulls(payload))
        c.check("%s: no value is the string 'null'%s" % (tag, (" (" + ", ".join(bad) + ")") if bad else ""), not bad)
    err = read(base + ".err")
    lines = (err or "").splitlines()
    wrong = []
    gap = (nf_stat or "").startswith("absent") and payload is not None \
        and payload.get("version") in NF_STAT_GAP_VERSIONS
    for line in lines:
        if nf_stat is not None and NF_STAT in line:
            # Neither a log line nor an allow entry excuses it: the target's
            # answer does, for the known gap only.
            if gap and NF_STAT_GAP.match(line):
                c.info("%s: known gap of agent %s, accepted as %s is absent here: %s"
                       % (tag, payload.get("version"), NF_STAT, line))
            else:
                wrong.append(line)
            continue
        if LOG_LINE.match(line) and not any(m in line for m in MARKERS):
            continue
        hit = next((a for a in allow if a["rx"].search(line)), None)
        if hit:
            hit["hits"] += 1
            c.info("%s: stderr line allowed by %s: %s" % (tag, hit["where"], line))
            continue
        wrong.append(line)
    c.check("%s: stderr holds only log lines without an error marker (%d lines)%s"
            % (tag, len(lines), "".join("\n       | " + w for w in wrong)), err is not None and not wrong)
    return payload


def entries(table, scope):
    return [e for e in table if any(fnmatch.fnmatchcase(scope, g) for g in e[0].split())]


def check_core(c, tag, payload, core, gaps=None, delta_nullable=()):
    for key in sorted(core):
        pred = core[key]
        v = payload.get(key, "<missing>")
        ok = pred(v) or (key in delta_nullable and (v is None or is_num(v)))
        if gaps and any(fnmatch.fnmatchcase(key, g) for g in gaps):
            continue  # a gap: check_measured's
        shown = json.dumps(v)
        if len(shown) > 80:
            shown = shown[:77] + "..."
        c.check("%s: %s is %s (got %s)" % (tag, key, pred.desc, shown), ok)


def check_measured(c, tag, payload, scope, core, own=()):
    """Every key measured, except NULL_OK and VARIES for SCOPE and the keys OWN
    names (another check holds them); a CORE key in NULL_OK is a gap in the
    CORE set."""
    how = {}
    unused = []
    for name in ("NULL_OK", "VARIES"):
        for _, glob, why in entries(NULL_OK if name == "NULL_OK" else VARIES, scope):
            keys = [k for k in payload if fnmatch.fnmatchcase(k, glob)]
            if not keys:
                unused.append("%s %s" % (name, glob))
            for k in keys:
                if k in how and how[k][0] != name:
                    c.check("%s: %s is in both NULL_OK and VARIES" % (tag, k), False)
                how[k] = (name, why)
    c.check("%s: every NULL_OK/VARIES entry names a key%s" % (tag, (" (renamed? " + ", ".join(unused) + ")") if unused else ""),
            not unused)
    excused = {"NULL_OK": [], "VARIES": []}
    wrong = []
    for key, v in payload.items():
        if key in own:
            continue
        is_measured = core[key](v) if key in core else measured(v)
        if key in how:
            name, why = how[key]
            if name == "NULL_OK" and is_measured:
                c.check("%s: NULL_OK %s is measured after all (%s) - stale, remove it (it said: %s)"
                        % (tag, key, json.dumps(v)[:60], why), False)
            elif not is_measured:
                excused[name].append(key)
        elif key not in core and not is_measured:
            wrong.append("%s is %s" % (key, json.dumps(v)))
    n_other = len([k for k in payload if k not in core and k not in how and k not in own])
    c.check("%s: every other key is measured (%d keys)%s" % (
        tag, n_other, "".join("\n       | " + w + " - a collector broke, or NULL_OK/VARIES it with the reason"
                              for w in wrong)), not wrong)
    for name in ("NULL_OK", "VARIES"):
        if excused[name]:
            c.info("%s: not measured, as %s says (%d): %s" % (tag, name, len(excused[name]), ", ".join(excused[name])))


def nf_stat_probe(c, out, prefix, label):
    """What the target said of NF_STAT; "" when it said nothing (a FAIL)."""
    text = read(os.path.join(out, prefix + "nf_stat.txt"))
    said = (text or "").strip()
    ok = said == "present" or said.startswith("absent: ")
    c.check("%s: the target says whether %s exists (%s)"
            % (label, NF_STAT, said if text is not None else "no %snf_stat.txt" % prefix), ok)
    if ok and said != "present":
        c.info("%s: %s is %s - %s cannot be measured here and must be null"
               % (label, NF_STAT, said, ", ".join(NF_STAT_KEYS)))
    return said if ok else ""


def check_owrt_run(c, tag, base, version, allow, nf_stat):
    """check_run for agent_openwrt.sh, then the counters NF_STAT gives."""
    payload = check_run(c, tag, base, "openwrt", version, allow, nf_stat)
    if payload is not None and nf_stat.startswith("absent"):
        got = {k: payload.get(k, "<missing>") for k in NF_STAT_KEYS}
        c.check("%s: conntrack counters null, as %s is absent (got %s)" % (tag, NF_STAT, json.dumps(got)),
                all(v is None for v in got.values()))
    return payload


def boot_up(c, out, ver):
    text = read(os.path.join(out, "%s_boot_fail.txt" % ver))
    c.check("%s: boot.sh brought every service up (not up: %s)"
            % (ver, "no %s_boot_fail.txt" % ver if text is None else (text.strip() or "none")),
            text is not None and not text.strip())


def first_run_honest(c, tag, payload, keys):
    got = {k: payload.get(k, "<missing>") for k in keys}
    c.check("%s: first run has no delta yet (%s null, got %s)" % (tag, "/".join(keys), json.dumps(got)),
            all(v is None for v in got.values()))


# --- selftest ----------------------------------------------------------------

def selftest():
    """The NF_STAT rules on their own samples: one image run through the calls
    main makes (check_measured with no NULL_OK scope and no CORE)."""
    failed = []

    def t(label, cond):
        print(("ok    " if cond else "FAIL  ") + label)
        if not cond:
            failed.append(label)

    absent = "absent: nf_conntrack is loaded, the kernel has no CONFIG_NF_CONNTRACK_PROCFS"
    leak = "agent_openwrt.sh: line 1922: can't open %s: no such file" % NF_STAT
    log = "2026-09-28 05:39:04 - Dry run, nothing sent"

    def run(said, version="0.1.12", err=(log,), ct=7, prefix="24.10_"):
        """The labels of the checks that failed."""
        d = tempfile.mkdtemp()
        try:
            base = os.path.join(d, prefix + "r2")
            payload = {"agent_type": "openwrt", "version": version}
            payload.update((k, ct) for k in NF_STAT_KEYS)
            with open(base + ".json", "w") as f:
                json.dump(payload, f)
            with open(base + ".err", "w") as f:
                f.write("".join(line + "\n" for line in err))
            with open(base + ".rc", "w") as f:
                f.write("0\n")
            if said is not None:
                with open(os.path.join(d, prefix + "nf_stat.txt"), "w") as f:
                    f.write(said + "\n")
            c = Checker()
            with contextlib.redirect_stdout(io.StringIO()):
                nf = nf_stat_probe(c, d, prefix, "p")
                p = check_owrt_run(c, prefix + "r2", base, version, [], nf)
                check_measured(c, prefix + "r2", p, "selftest", {}, NF_STAT_KEYS if nf.startswith("absent") else ())
            return c.failed
        finally:
            shutil.rmtree(d)

    def only(fails, *words):
        return len(fails) == 1 and all(w in fails[0] for w in words)

    t("present: counted conntrack and a plain log line pass", run("present") == [])
    t("present: the 0.1.12 can't-open line fails", only(run("present", err=(log, leak)), "stderr", leak))
    t("present: even a log line naming the file fails",
      only(run("present", err=(log[:22] + "reading " + NF_STAT,)), "stderr", NF_STAT))
    t("present: a null counter fails as a broken collector",
      only(run("present", ct=None), "every other key", "conntrack_drop is null"))
    t("absent, 0.1.12: the can't-open line is the known gap, null counters pass",
      run(absent, err=(log, leak), ct=None) == [])
    t("absent, 0.1.12: hw's ./agent_openwrt.sh spelling of it too",
      run(absent, err=("./" + leak,), ct=None, prefix="") == [])
    t("absent, 0.1.13: the same line fails (0.1.13 must not print it)",
      only(run(absent, version="0.1.13", err=(leak,), ct=None), "stderr", leak))
    t("absent, 0.1.1: the gap is 0.1.12's alone, not a prefix of it",
      only(run(absent, version="0.1.1", err=(leak,), ct=None), "stderr", leak))
    t("absent, 0.1.12: the line with more after it fails",
      only(run(absent, err=(leak + "; retrying",), ct=None), "stderr", leak))
    fails = run(absent, err=(leak, "sh: foo: not found"), ct=None)
    t("absent, 0.1.12: any other stderr line still fails", only(fails, "stderr", "sh: foo") and leak not in fails[0])
    other = "cat: can't open '%s': No such file or directory" % NF_STAT
    t("absent, 0.1.12: another line naming the file fails", only(run(absent, err=(other,), ct=None), "stderr", other))
    t("absent: a counter that is a number fails (it would be invented)",
      only(run(absent, err=(leak,), ct=0), "conntrack counters null"))
    fails = run(None, err=(leak,), ct=None)
    t("no answer from the target fails, and the line is not excused",
      any("the target says" in f for f in fails) and any("stderr" in f and leak in f for f in fails))

    print("assert_real_payload selftest: %s" % ("all passed" if not failed else "%d failed" % len(failed)))
    return 1 if failed else 0


def main(argv):
    if argv == ["selftest"]:
        return selftest()
    args = [a for a in argv if not a.startswith("--")]
    single = "--single" in argv
    agent_file = None
    if "--agent" in argv:
        i = argv.index("--agent")
        agent_file = argv[i + 1]
        args.remove(agent_file)
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    profile, out = args
    c = Checker()
    allow = load_allow(profile)

    if profile.startswith("openwrt-") or profile == "hw":
        version = agent_version(agent_file or AGENTS["openwrt"])
        prefix = "" if profile == "hw" else profile.split("-", 1)[1] + "_"
        runs = ["r1"] if single else ["r1", "r2"]
        nf_stat = nf_stat_probe(c, out, prefix, prefix[:-1] or profile)
        payloads = {}
        for r in runs:
            payloads[r] = check_owrt_run(c, prefix + r, os.path.join(out, prefix + r), version, allow, nf_stat)
        core = owrt_core(profile)
        if single:
            if payloads["r1"] is not None:
                check_core(c, prefix + "r1", payloads["r1"], core, None, OWRT_DELTA)
        else:
            if payloads["r1"] is not None:
                first_run_honest(c, prefix + "r1", payloads["r1"], ("cpu", "net"))
            if payloads["r2"] is not None:
                if profile == "hw":
                    check_core(c, "r2", payloads["r2"], core)
                else:
                    gaps = {e[1] for e in entries(NULL_OK, profile)}
                    check_core(c, prefix + "r2", payloads["r2"], core, gaps)
                    check_measured(c, prefix + "r2", payloads["r2"], profile, core,
                                   NF_STAT_KEYS if nf_stat.startswith("absent") else ())
        if profile != "hw":
            boot_up(c, out, prefix[:-1])
    elif profile in ("ubuntu", "alpine", "rocky"):
        for kind, agent_type in (("sh", "bash"), ("py", "python")):
            version = agent_version(AGENTS[agent_type])
            p1 = check_run(c, "%s_%s1" % (profile, kind), os.path.join(out, "%s_%s1" % (profile, kind)),
                           agent_type, version, allow)
            p2 = check_run(c, "%s_%s2" % (profile, kind), os.path.join(out, "%s_%s2" % (profile, kind)),
                           agent_type, version, allow)
            if p1 is not None:
                first_run_honest(c, "%s_%s1" % (profile, kind), p1, LINUX_DELTA)
            if p2 is not None:
                scope = "%s/%s" % (profile, kind)
                core = linux_core(kind)
                check_core(c, "%s_%s2" % (profile, kind), p2, core, {e[1] for e in entries(NULL_OK, scope)})
                check_measured(c, "%s_%s2" % (profile, kind), p2, scope, core)
    else:
        print("unknown profile %r" % profile, file=sys.stderr)
        return 2

    # An exception nothing needs any more hides the next real one.
    for a in allow:
        c.check("%s: allow entry still matches a line (%s)" % (a["where"], a["rx"].pattern), a["hits"] > 0)

    print("%s: %s" % (profile, "all passed" if not c.failed else "%d failed" % len(c.failed)))
    return 1 if c.failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

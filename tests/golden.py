#!/usr/bin/env python3
"""Golden payloads: the shape of what each agent prints, pinned.

    golden.py check DIR...            every run DIR/payload_runs.txt lists
    golden.py check AGENT FILE...     these payload files
    golden.py update AGENT [--accept KEY]... [--unverified] SRC...
                                      rewrite golden/AGENT.json from kept runs
    golden.py selftest                the rules below on their own samples

AGENT is openwrt, linux-bash or linux-python; golden/AGENT.json is one plain
payload as the agent prints it, normalised (the monitoring repo POSTs it to
its API as it is). A harness lists its payloads in out/payload_runs.txt, one
"AGENT TAG" per line (TAG.json next to it), "AGENT -TAG" for a run that must
print nothing. There is no glob: out/ holds kept copies and planted files too,
and a listed payload that does not parse fails.

The shape is read off the golden payload; only null means null:
- the top-level keys must be exactly the golden's: a missing key fails, a new
  one fails with the command that takes it in;
- JSON types, with int and float both "number"; null is compatible with every
  type (unmeasured is null, anywhere), and a golden null pins no type (the key
  is listed as unpinned);
- an object outside an array has exactly the golden object's keys, unless its
  path is a dynamic map in MAPS (only the values' type is checked);
- an array item is compared with all golden items at that path merged: its
  keys within their union and covering their intersection, types compatible;
  an empty array always passes.

update SRC is a directory with a payload_runs.txt (its runs for AGENT, in the
order listed) and the .passed its harness writes once its own checks passed,
or a payload file with --unverified; the order of SRC is the priority. All
sources must have the same top-level keys. A golden value still compatible
with every source is kept, so the file does not churn - except a golden null,
which takes the first measured value, and "version", which follows the
source. A new or incompatible key takes the first non-null value, normalised
(identifiers masked); arrays take items from later sources that add item
keys, up to 6. A key that changes its shape (retyped) or goes (dropped) is
refused, and the file left as it was, unless --accept names it: the agent
change intends it. Python 3.9: the macOS host python runs it too.
"""
import collections
import copy
import ipaddress
import json
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN_DIR = os.path.join(HERE, "golden")
AGENTS = ("openwrt", "linux-bash", "linux-python")
UPDATE_HINT = "run tests/update_golden.sh %s (tests/README.md, Golden payloads)"


def hint(agent):
    return UPDATE_HINT % ("openwrt" if agent == "openwrt" else "linux")

# Objects whose keys are data (a service name), not a schema.
MAPS = {
    "openwrt": ("service_restarts",),
    "linux-bash": (),
    "linux-python": (),
}
MAX_ITEMS = 6

# Identifiers never go into the repo; kept values are not re-masked.
FIXED = {
    "agent_key": "",
    "kernel": "6.6.0",
    "agent_time": 1790000000,
    "boot_time": 1789990000,
    "wan_last_reconnect": 1789995000,
}
ADDRESS_KEYS = ("wan_ipv4", "wan_ipv6", "wan_gateway", "wan_dns", "dns_servers", "lte_ipv4")
MASK_NET = ipaddress.ip_network("192.0.2.0/24")
IPV4 = re.compile(r"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])")


def jtype(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "boolean"
    if isinstance(v, (int, float)):
        return "number"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    return "object"


def no_dups(pairs):
    seen = collections.OrderedDict()
    for k, v in pairs:
        if k in seen:
            raise ValueError("duplicate key %r" % k)
        seen[k] = v
    return seen


def loads(text):
    return json.loads(text, object_pairs_hook=no_dups)


def load(path):
    with open(path, encoding="utf-8") as f:
        return loads(f.read())


def golden_path(agent):
    return os.path.join(GOLDEN_DIR, agent + ".json")


def join(path, key):
    return key if not path else path + "." + key


# --- the shape check ---------------------------------------------------------

def shape_errors(golden, value, path, maps, info=None):
    """What `value` breaks of the shape `golden` pins at `path`.

    golden: the list of golden values at this path (one outside an array,
    every item of every golden array at that path inside one)."""
    errs = []
    _shape(golden, value, path, maps, False, errs, info if info is not None else set())
    return errs


def _shape(golden, value, path, maps, in_array, errs, info):
    if value is None:
        return
    pinned = [g for g in golden if g is not None]
    if not pinned:
        info.add(path)
        return
    want = sorted({jtype(g) for g in pinned})
    got = jtype(value)
    if got not in want:
        errs.append("%s: %s, golden %s" % (path, got, "/".join(want)))
        return
    if got == "object":
        objs = [g for g in pinned if isinstance(g, dict)]
        if path in maps:
            for k, v in value.items():
                _shape([x for o in objs for x in o.values()], v, path + "{}", maps, in_array, errs, info)
            return
        union = set().union(*[set(o) for o in objs])
        common = set.intersection(*[set(o) for o in objs])
        new = [k for k in value if k not in union]
        missing = sorted(common - set(value))
        for k in new:
            errs.append("%s: new key" % join(path, k))
        for k in missing:
            errs.append("%s: missing key" % join(path, k))
        for k, v in value.items():
            if k in union:
                _shape([o[k] for o in objs if k in o], v, join(path, k), maps, in_array, errs, info)
    elif got == "array":
        items = [x for g in pinned if isinstance(g, list) for x in g]
        for v in value:
            _shape(items, v, path + "[]", maps, True, errs, info)


def check_payload(agent, golden, payload, label, out):
    """Top level: exactly the golden's keys, then the shape of each."""
    errs = []
    info = set()
    for k in golden:
        if k not in payload:
            errs.append("%s: missing key (dropped from the agent? %s)" % (k, hint(agent)))
    for k in payload:
        if k not in golden:
            errs.append("%s: new key - %s" % (k, hint(agent)))
    for k, v in payload.items():
        if k in golden:
            errs.extend(shape_errors([golden[k]], v, k, MAPS[agent], info))
    if errs:
        out.append("%s: %s" % (label, "; ".join(errs[:12]) + (" (+%d more)" % (len(errs) - 12) if len(errs) > 12 else "")))
    return not errs


def read_manifest(d):
    """[(agent, tag, must_be_empty)] from DIR/payload_runs.txt."""
    path = os.path.join(d, "payload_runs.txt")
    runs = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2 or parts[0] not in AGENTS:
                raise ValueError("%s:%d: not 'AGENT TAG': %r" % (path, n, line))
            tag = parts[1]
            runs.append((parts[0], tag.lstrip("-"), tag.startswith("-")))
    return runs


def cmd_check(args):
    failed = []
    if args and args[0] in AGENTS:
        agent, files = args[0], args[1:]
        todo = [(agent, f, False) for f in files]
        if not files:
            print("check %s: no payload given" % agent, file=sys.stderr)
            return 2
    else:
        todo = []
        for d in args:
            try:
                runs = read_manifest(d)
            except (OSError, ValueError) as e:
                print("FAIL  golden: %s" % e)
                return 1
            if not runs:
                print("FAIL  golden: %s/payload_runs.txt lists no run" % d)
                return 1
            todo += [(a, os.path.join(d, t + ".json"), empty) for a, t, empty in runs]
    goldens = {}
    counts = collections.Counter()
    empties = collections.Counter()
    unpinned = {}
    for agent, f, must_be_empty in todo:
        label = os.path.relpath(f) if not os.path.isabs(f) else os.path.basename(f)
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError as e:
            failed.append("%s: %s" % (label, e))
            continue
        if must_be_empty:
            if text.strip():
                failed.append("%s: listed as a run that prints nothing, printed %d bytes" % (label, len(text)))
            else:
                empties[agent] += 1
            continue
        if agent not in goldens:
            try:
                goldens[agent] = load(golden_path(agent))
            except (OSError, ValueError) as e:
                print("FAIL  golden %s: %s unreadable (%s)" % (agent, golden_path(agent), e))
                return 1
            unpinned[agent] = sorted(k for k, v in goldens[agent].items() if v is None)
        try:
            payload = loads(text)
        except ValueError as e:
            failed.append("%s: not one JSON object (%s)" % (label, e))
            continue
        if not isinstance(payload, dict):
            failed.append("%s: not a JSON object" % label)
            continue
        if check_payload(agent, goldens[agent], payload, label, failed):
            counts[agent] += 1
    for agent in AGENTS:
        if counts[agent] or empties[agent]:
            print("ok    golden %s: %d payloads have the shape of golden/%s.json%s" % (
                agent, counts[agent], agent,
                " (%d runs printed nothing, as listed)" % empties[agent] if empties[agent] else ""))
        if agent in unpinned and unpinned[agent]:
            print("info  golden %s: %d keys unpinned (golden null, any type passes): %s" % (
                agent, len(unpinned[agent]), ", ".join(unpinned[agent])))
    for f in failed:
        print("FAIL  golden: " + f)
    return 1 if failed else 0


# --- update ------------------------------------------------------------------

def mask_addresses(v, seen):
    def one(s):
        def sub(m):
            a = m.group(1)
            try:
                ip = ipaddress.ip_address(a)
            except ValueError:
                return a
            if ip in MASK_NET:
                return a  # masked already (a kept value)
            if a not in seen:
                seen[a] = "192.0.2.%d" % (len(seen) + 1)
            return seen[a]
        s = IPV4.sub(sub, s)
        return re.sub(r"\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F:]*\b",
                      lambda m: m.group(0) if not _is_global6(m.group(0)) else "2001:db8::1", s)
    if isinstance(v, str):
        return one(v)
    if isinstance(v, list):
        return [mask_addresses(x, seen) for x in v]
    return v


def _is_global6(s):
    try:
        return ipaddress.ip_address(s.split("/")[0]).is_global
    except ValueError:
        return False


def normalise(agent, key, value, seen):
    if value is None:
        return None
    if key == "hostname":
        return "golden-openwrt" if agent == "openwrt" else "golden-linux"
    if key in FIXED:
        return FIXED[key] if jtype(FIXED[key]) == jtype(value) else value
    if key in ADDRESS_KEYS:
        return mask_addresses(value, seen)
    return copy.deepcopy(value)


IPV6ISH = re.compile(r"[0-9a-fA-F]{0,4}(?::[0-9a-fA-F]{0,4}){2,7}")


def public_addresses(v, path=""):
    """Paths whose strings carry a public address: none may reach the repo
    (assert_openwrt_payload.py fails on one anywhere under tests/)."""
    out = []
    if isinstance(v, str):
        for a in IPV4.findall(v) + IPV6ISH.findall(v):
            try:
                ip = ipaddress.ip_address(a)
            except ValueError:
                continue
            if not (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_unspecified):
                out.append("%s (%s)" % (path, a))
    elif isinstance(v, dict):
        for k, x in v.items():
            out += public_addresses(x, join(path, k))
    elif isinstance(v, list):
        for x in v:
            out += public_addresses(x, path + "[]")
    return out


def fill(value, others, path, maps):
    """Nested golden nulls take the first measured value of the sources, and
    arrays take items that add keys, so as much of the shape as any source
    shows gets pinned."""
    if isinstance(value, dict) and path not in maps:
        for k in list(value):
            sub = [o[k] for o in others if isinstance(o, dict) and k in o]
            if value[k] is None:
                value[k] = next((copy.deepcopy(x) for x in sub if x is not None), None)
            value[k] = fill(value[k], sub, join(path, k), maps)
    elif isinstance(value, list):
        keys = set().union(*[set(x) for x in value if isinstance(x, dict)]) if value else set()
        kinds = {jtype(x) for x in value}
        for o in others:
            if not isinstance(o, list):
                continue
            for item in o:
                if len(value) >= MAX_ITEMS:
                    break
                adds = jtype(item) not in kinds or (isinstance(item, dict) and set(item) - keys)
                if adds and item is not None:
                    value.append(copy.deepcopy(item))
                    kinds.add(jtype(item))
                    if isinstance(item, dict):
                        keys |= set(item)
    return value


def build(agent, old, sources):
    """The new golden payload from SOURCES [(label, payload)], priority first.
    Returns (golden, report) or raises ValueError."""
    maps = MAPS[agent]
    first_label, first = sources[0]
    for label, p in sources[1:]:
        if set(p) != set(first):
            raise ValueError("%s and %s print different keys (+%s -%s): one of them is not this version"
                             % (label, first_label, sorted(set(p) - set(first)), sorted(set(first) - set(p))))
    new = collections.OrderedDict()
    # changed: "version" and golden nulls or arrays that got a value, all
    # routine; retyped: a pinned value no source fits any more.
    report = {"added": [], "changed": [], "retyped": [], "dropped": [], "unpinned": []}
    seen = {}
    for key in first:
        vals = [p[key] for _, p in sources]
        keep = (old is not None and key in old and key != "version" and old[key] is not None
                and all(not shape_errors([old[key]], v, key, maps) for v in vals))
        if keep:
            value = copy.deepcopy(old[key])
        else:
            value = next((normalise(agent, key, v, seen) for v in vals if v is not None), None)
            if old is None or key not in old:
                report["added"].append(key)
            elif old[key] is not None and (key != "version" or jtype(old[key]) != jtype(value)):
                report["retyped"].append(key)
            elif old[key] != value:
                report["changed"].append(key)
        value = fill(value, vals, key, maps)
        if key in ADDRESS_KEYS:
            value = mask_addresses(value, seen)
        if keep and value != old[key]:
            report["changed"].append(key)  # a nested null or an array got filled
        new[key] = value
        if value is None:
            report["unpinned"].append(key)
    if old is not None:
        report["dropped"] = [k for k in old if k not in new]
    leaks = public_addresses(new)
    if leaks:
        raise ValueError("a public address would go into the golden file: " + ", ".join(leaks))
    # Every source must pass what it was made from; if one does not, a path
    # is a map not declared in MAPS, or the sources disagree on a type.
    bad = []
    for label, p in sources:
        check_payload(agent, new, p, label, bad)
    if bad:
        raise ValueError("the sources do not fit one shape (a dynamic map missing from MAPS?):\n  "
                         + "\n  ".join(bad))
    return new, report


def dump(payload):
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


REPORT = ("added", "changed", "retyped", "dropped", "unpinned")


def cmd_update(argv):
    accept = set()
    unverified = False
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == "--accept" and i + 1 < len(argv):
            accept.add(argv[i + 1])
            i += 2
            continue
        if argv[i] == "--unverified":
            unverified = True
        else:
            args.append(argv[i])
        i += 1
    if len(args) < 2 or args[0] not in AGENTS:
        print(__doc__, file=sys.stderr)
        return 2
    agent = args[0]
    sources = []
    for src in args[1:]:
        if os.path.isdir(src):
            # A kept out/ is kept whether its run passed or not.
            if not os.path.isfile(os.path.join(src, ".passed")):
                print("update %s refused: %s has no .passed - its harness did not pass (or did not finish),"
                      " and a golden file is never made from such a run" % (agent, src), file=sys.stderr)
                return 1
            runs = [(t, e) for a, t, e in read_manifest(src) if a == agent]
            for tag, must_be_empty in runs:
                if not must_be_empty:
                    f = os.path.join(src, tag + ".json")
                    sources.append((f, load(f)))
        elif not unverified:
            print("update %s refused: %s is a file, not a harness's kept out/ - no check stands behind it;"
                  " --unverified takes it anyway" % (agent, src), file=sys.stderr)
            return 1
        else:
            sources.append((src, load(src)))
    if not sources:
        print("update %s: no payload of this agent in %s" % (agent, " ".join(args[1:])), file=sys.stderr)
        return 1
    path = golden_path(agent)
    old = load(path) if os.path.exists(path) else None
    try:
        new, report = build(agent, old, sources)
    except ValueError as e:
        print("update %s refused: %s" % (agent, e), file=sys.stderr)
        return 1
    print("golden/%s.json from %d payloads: %d keys" % (agent, len(sources), len(new)))
    for what in REPORT:
        print("  %-8s %d%s" % (what, len(report[what]), (": " + ", ".join(report[what])) if report[what] else ""))
    breaking = report["retyped"] + report["dropped"]
    unused = sorted(accept - set(breaking))
    if unused:
        print("  (--accept %s: not retyped or dropped here)" % ", ".join(unused))
    refused = [k for k in breaking if k not in accept]
    if refused:
        sys.stdout.flush()
        print("update %s refused, golden/%s.json unchanged: %s changed shape or went. If the agent change"
              " intends it, run again with --accept KEY for each and commit the golden diff with that change."
              % (agent, agent, ", ".join(refused)), file=sys.stderr)
        return 1
    os.makedirs(GOLDEN_DIR, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(dump(new))
    return 0


# --- selftest ----------------------------------------------------------------

def cmd_selftest(_args):
    failed = []

    def t(label, cond):
        print(("ok    " if cond else "FAIL  ") + label)
        if not cond:
            failed.append(label)

    agent = "openwrt"
    golden = loads('{"agent_key": "", "version": "1.0", "cpu": 1.5, "hostname": "g", "temp": null,'
                   ' "service_restarts": {"dnsmasq": 2}, "agent_tools": {"iw": true, "pkg": "opkg"},'
                   ' "disks": [{"name": "sda", "smart": {"temp": 40}},'
                   ' {"name": "nvme0n1", "smart": {"temp": 30, "spare": 100}}], "radios": []}')

    def errs(payload_text):
        out = []
        check_payload(agent, golden, loads(payload_text), "p", out)
        return out[0] if out else ""

    base = dump(golden)
    t("the golden itself passes", errs(base) == "")
    p = loads(base); del p["hostname"]
    t("a missing key fails", "hostname: missing key" in errs(json.dumps(p)))
    p = loads(base); p["wan_new"] = 1
    e = errs(json.dumps(p))
    t("a new key fails and names the update command", "wan_new: new key" in e and "update_golden.sh openwrt" in e)
    p = loads(base); p["cpu"] = "1.5"
    t("a number that became a string fails", "cpu: string, golden number" in errs(json.dumps(p)))
    p = loads(base); p["cpu"] = 7
    t("int and float are both a number", errs(json.dumps(p)) == "")
    p = loads(base); p["cpu"] = True
    t("a boolean is not a number", "cpu: boolean" in errs(json.dumps(p)))
    p = loads(base); p["cpu"] = None; p["agent_tools"] = None; p["disks"] = None
    t("null passes wherever a value is pinned", errs(json.dumps(p)) == "")
    info = set()
    p = loads(base); p["temp"] = {"any": ["thing"]}
    check_payload(agent, golden, p, "p", [])
    shape_errors([golden["temp"]], p["temp"], "temp", MAPS[agent], info)
    t("a golden null pins no type and is reported as unpinned", errs(json.dumps(p)) == "" and "temp" in info)
    p = loads(base); p["disks"][0]["smart"]["crc"] = 0
    t("a new key in an array item fails", "disks[].smart.crc: new key" in errs(json.dumps(p)))
    p = loads(base); p["disks"] = [{"name": "sdb", "smart": {"temp": 50, "spare": 90}}, {"name": "sdc", "smart": {"temp": 5}}]
    t("array items may carry any golden item's keys (SATA and NVMe)", errs(json.dumps(p)) == "")
    p = loads(base); p["disks"] = [{"smart": {"temp": 5}}]
    t("an array item without a key every golden item has fails", "disks[].name: missing key" in errs(json.dumps(p)))
    p = loads(base); p["radios"] = [{"band": "5g"}]; p["disks"] = []
    t("items under a golden [] are unpinned, an empty array passes", errs(json.dumps(p)) == "")
    p = loads(base); p["service_restarts"] = {"odhcpd": 1, "uhttpd": 4}
    t("a dynamic map may change its keys", errs(json.dumps(p)) == "")
    p = loads(base); p["service_restarts"] = {"odhcpd": "x"}
    t("a dynamic map's values keep their type", "service_restarts{}: string" in errs(json.dumps(p)))
    p = loads(base); p["agent_tools"] = {"iw": True, "pkg": "apk", "tc": False}
    t("a fixed object that gains a key fails", "agent_tools.tc: new key" in errs(json.dumps(p)))
    try:
        loads('{"cpu": 1, "cpu": 2}')
        dup = False
    except ValueError:
        dup = True
    t("a key printed twice is refused (PHP would keep only the last)", dup)

    s1 = loads('{"agent_key": "SECRET", "version": "1.1", "hostname": "router7", "cpu": 3, "temp": 41,'
               ' "wan_ipv4": "203.0.113.9", "service_restarts": {}, "radios": [],'
               ' "tools": {"iw": null, "tc": false}}')
    s2 = loads('{"agent_key": "SECRET", "version": "1.1", "hostname": "router7", "cpu": 4, "temp": 40,'
               ' "wan_ipv4": "10.0.0.2", "service_restarts": {"x": 1}, "radios": [{"band": "2g"}],'
               ' "tools": {"iw": true, "tc": false}}')
    new, rep = build(agent, None, [("s1", s1), ("s2", s2)])
    t("update masks identifiers", new["agent_key"] == "" and new["hostname"] == "golden-openwrt"
      and new["wan_ipv4"].startswith("192.0.2."))
    t("update fills nested nulls and array items from later sources",
      new["tools"]["iw"] is True and new["radios"] == [{"band": "2g"}])
    old0 = copy.deepcopy(new); old0["radios"] = []
    _, rep0 = build(agent, old0, [("s2", s2)])
    t("an array that got items is reported as changed", rep0["changed"] == ["radios"] and rep0["retyped"] == [])
    old = copy.deepcopy(new)
    old["temp"] = None
    old["version"] = "1.0"
    old["gone"] = 1
    s3 = copy.deepcopy(s1); s3["cpu"] = 99; s3["version"] = "1.2"
    new2, rep2 = build(agent, old, [("s3", s3)])
    t("update keeps a compatible value, refreshes version, fills a golden null, drops a gone key",
      new2["cpu"] == old["cpu"] and new2["version"] == "1.2" and new2["temp"] == 41
      and rep2["dropped"] == ["gone"] and rep2["changed"] == ["version", "temp"] and rep2["retyped"] == [])
    s8 = copy.deepcopy(s1); s8["cpu"] = "3"; s8["radios"] = [{"x": 1}]; s8["version"] = "1.2"
    _, rep3 = build(agent, new, [("s8", s8)])
    t("a number that became a string and a reshaped array item are retyped, not changed",
      rep3["retyped"] == ["cpu", "radios"] and rep3["changed"] == ["version"])
    s4 = copy.deepcopy(s1); s4["new_key"] = 1
    try:
        build(agent, None, [("s1", s1), ("s4", s4)])
        refused = False
    except ValueError as e:
        refused = "new_key" in str(e)
    t("update refuses sources with different keys and names them", refused)
    s5 = copy.deepcopy(s1); s5["tools"] = {"iw": True}
    try:
        build(agent, None, [("s1", s1), ("s5", s5)])
        refused = False
    except ValueError as e:
        refused = "tools.tc" in str(e)
    t("update refuses objects that differ outside MAPS and names the path", refused)
    # Put together at run time: no public address may stand in a file here.
    s6 = copy.deepcopy(s1); s6["note"] = "via " + ".".join(["8"] * 4)
    try:
        build(agent, None, [("s6", s6)])
        refused = False
    except ValueError as e:
        refused = "public address" in str(e)
    s7 = copy.deepcopy(s1); s7["note"] = "via " + ":".join(["2a00", "1450", "4001", "80e", ""]) + ":200e"
    try:
        build(agent, None, [("s7", s7)])
        refused6 = False
    except ValueError as e:
        refused6 = "public address" in str(e)
    t("update never writes a public address into the repo (IPv4, IPv6)", refused and refused6)

    d = tempfile.mkdtemp()
    try:
        with open(os.path.join(d, "a.json"), "w") as f:
            f.write("")
        with open(os.path.join(d, "payload_runs.txt"), "w") as f:
            f.write("openwrt a\n")
        t("a manifest line reads as agent, tag, must-be-empty", read_manifest(d) == [("openwrt", "a", False)])
        with open(os.path.join(d, "payload_runs.txt"), "w") as f:
            f.write("openwrt -a\n")
        t("'-TAG' is a run that must print nothing", read_manifest(d) == [("openwrt", "a", True)])
    finally:
        for n in os.listdir(d):
            os.remove(os.path.join(d, n))
        os.rmdir(d)

    # update end to end, on a golden file of its own (GOLDEN_DIR swapped).
    global GOLDEN_DIR
    real_dir, GOLDEN_DIR = GOLDEN_DIR, tempfile.mkdtemp()
    d = tempfile.mkdtemp()
    try:
        g = os.path.join(GOLDEN_DIR, "openwrt.json")
        with open(g, "w") as f:
            f.write(dump(new))
        before = dump(new)

        def run_update(payload, *flags, passed=True):
            with open(os.path.join(d, "r2.json"), "w") as f:
                f.write(json.dumps(payload))
            with open(os.path.join(d, "payload_runs.txt"), "w") as f:
                f.write("openwrt r2\n")
            if passed:
                open(os.path.join(d, ".passed"), "w").close()
            elif os.path.exists(os.path.join(d, ".passed")):
                os.remove(os.path.join(d, ".passed"))
            saved = sys.stdout, sys.stderr
            sys.stdout = sys.stderr = open(os.devnull, "w")
            try:
                return cmd_update(["openwrt"] + list(flags) + [d])
            finally:
                sys.stdout.close()
                sys.stdout, sys.stderr = saved

        def golden_now():
            with open(g) as f:
                return f.read()

        t("update takes a kept run with .passed", run_update(s2) == 0)
        with open(g, "w") as f:
            f.write(before)
        t("update refuses a kept run without .passed and leaves the golden file",
          run_update(s2, passed=False) == 1 and golden_now() == before)
        p = copy.deepcopy(s2); p["cpu"] = "4"
        t("update refuses a retyped key", run_update(p) == 1 and golden_now() == before)
        t("update takes a retyped key named by --accept", run_update(p, "--accept", "cpu") == 0
          and loads(golden_now())["cpu"] == "4")
        with open(g, "w") as f:
            f.write(before)
        p = copy.deepcopy(s2); del p["temp"]
        t("update refuses a dropped key, takes it with --accept", run_update(p) == 1 and golden_now() == before
          and run_update(p, "--accept", "temp") == 0 and "temp" not in loads(golden_now()))
        with open(g, "w") as f:
            f.write(before)
        p = copy.deepcopy(s2); p["wan_new"] = 1
        t("an added key needs no --accept", run_update(p) == 0 and "wan_new" in loads(golden_now()))
        with open(g, "w") as f:
            f.write(before)
        with open(os.path.join(d, "one.json"), "w") as f:
            f.write(json.dumps(s2))
        saved = sys.stdout, sys.stderr
        sys.stdout = sys.stderr = open(os.devnull, "w")
        try:
            bare = cmd_update(["openwrt", os.path.join(d, "one.json")])
            bare_ok = cmd_update(["openwrt", "--unverified", os.path.join(d, "one.json")])
        finally:
            sys.stdout.close()
            sys.stdout, sys.stderr = saved
        t("update refuses a bare payload file unless --unverified", bare == 1 and bare_ok == 0)
    finally:
        for x in (d, GOLDEN_DIR):
            for n in os.listdir(x):
                os.remove(os.path.join(x, n))
            os.rmdir(x)
        GOLDEN_DIR = real_dir

    print("golden selftest: %s" % ("all passed" if not failed else "%d failed" % len(failed)))
    return 1 if failed else 0


def main(argv):
    if not argv or argv[0] not in ("check", "update", "selftest"):
        print(__doc__, file=sys.stderr)
        return 2
    return {"check": cmd_check, "update": cmd_update, "selftest": cmd_selftest}[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

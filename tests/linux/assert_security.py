#!/usr/bin/env python3
"""Asserts on the security cases of agent.sh and agent.py
(run-security-cases.sh): remote actions, the --selfcheck gate, self-update
refusals and the rollback. Reads OUT/sec/*.facts, *.posts.jsonl, *.gets and
*.log; usage: assert_security.py OUT."""
import json
import os
import sys

SEC = os.path.join(sys.argv[1], "sec")
failed = []


def check(label, cond):
    print(("ok   " if cond else "FAIL "), label)
    if not cond:
        failed.append(label)


def facts(label):
    out = {}
    try:
        with open(os.path.join(SEC, label + ".facts"), encoding="utf-8") as f:
            for line in f:
                k, _, v = line.rstrip("\n").partition("=")
                out[k] = v
    except OSError:
        pass
    return out


def text(label, ext):
    try:
        with open(os.path.join(SEC, f"{label}.{ext}"), encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def posts(label):
    """(report versions, action results) the fake server received in the case."""
    reports, results = [], []
    for line in text(label, "posts.jsonl").splitlines():
        try:
            doc = json.loads(line)
        except ValueError:
            reports.append("<invalid JSON>")
            continue
        if "action_result" in doc:
            results.append(doc["action_result"])
        else:
            reports.append(doc.get("version"))
    return reports, results


for kind in ("sh", "py"):
    orig = facts(f"{kind}-orig")
    cur = orig.get("version")
    check(f"{kind}: harness built its fixtures", bool(orig.get("orig_sha")) and bool(orig.get("good_sha")))

    # --- Remote actions ---------------------------------------------------
    f = facts(f"{kind}-act-ts")
    _, res = posts(f"{kind}-act-ts")
    check(f"{kind}: a non-numeric timestamp runs nothing (no command substitution, no restart)",
          f.get("pwned") == "0" and f.get("restarts") == "0")
    check(f"{kind}: a non-numeric timestamp is ignored without an action result", res == [])
    check(f"{kind}: a non-numeric timestamp is logged", "nečíselné" in text(f"{kind}-act-ts", "log"))
    check(f"{kind}: a non-numeric timestamp does not end the run", f.get("rc") == "0")

    if kind == "sh":
        f = facts("sh-act-octal")
        _, res = posts("sh-act-octal")
        check("sh: a leading-zero timestamp is no octal error: the run goes on", f.get("rc") == "0")
        check("sh: a leading-zero timestamp is read as decimal (expired, refused)",
              f.get("restarts") == "0" and len(res) == 1 and res[0].get("status") == "failed"
              and "Vypršela" in res[0].get("message", ""))

    for case, name in (("act-traversal", "../../tmp/pwn"), ("act-dash", "-H")):
        f = facts(f"{kind}-{case}")
        _, res = posts(f"{kind}-{case}")
        check(f"{kind}: signed restart_service '{name}' runs nothing",
              f.get("pwned") == "0" and f.get("restarts") == "0")
        check(f"{kind}: signed restart_service '{name}' is refused as a bad service name",
              len(res) == 1 and res[0].get("status") == "failed" and "název služby" in res[0].get("message", ""))

    f = facts(f"{kind}-act-unit")
    _, res = posts(f"{kind}-act-unit")
    check(f"{kind}: signed restart_service 'bkfake.target' (a systemd target) runs nothing and is refused",
          f.get("restarts") == "0" and len(res) == 1 and res[0].get("status") == "failed"
          and "není služba" in res[0].get("message", ""))

    f = facts(f"{kind}-act-ok")
    _, res = posts(f"{kind}-act-ok")
    check(f"{kind}: a valid signed restart_service runs the service once", f.get("restarts") == "1")
    check(f"{kind}: ... and reports it executed", len(res) == 1 and res[0].get("status") == "executed")

    f = facts(f"{kind}-act-replay")
    _, res1 = posts(f"{kind}-act-replay-1")
    _, res = posts(f"{kind}-act-replay")
    check(f"{kind}: the same signed answer twice restarts the service once", f.get("restarts") == "1")
    check(f"{kind}: the replay is refused as a used nonce",
          [r.get("status") for r in res] == ["executed", "failed"] and "nonce už byl použit" in res[-1].get("message", ""))

    f = facts(f"{kind}-act-nonce-ro")
    _, res = posts(f"{kind}-act-nonce-ro")
    check(f"{kind}: a nonce that cannot be stored refuses the action",
          f.get("restarts") == "0" and len(res) == 1 and res[0].get("status") == "failed"
          and "nonce nejde" in res[0].get("message", ""))

    f = facts(f"{kind}-act-badsig")
    _, res = posts(f"{kind}-act-badsig")
    nonce_file = "agent.sh.nonces" if kind == "sh" else "vps_agent_action_nonces"
    check(f"{kind}: a bad signature is refused and burns no nonce",
          f.get("restarts") == "0" and len(res) == 1 and "HMAC" in res[0].get("message", "")
          and nonce_file not in f.get("files", "").split())

    f = facts(f"{kind}-act-notallowed")
    _, res = posts(f"{kind}-act-notallowed")
    check(f"{kind}: a signed action off ALLOWED_ACTIONS is refused",
          len(res) == 1 and res[0].get("status") == "failed" and "ALLOWED_ACTIONS" in res[0].get("message", ""))

    # --- --selfcheck --------------------------------------------------------
    f = facts(f"{kind}-sc-noenv")
    check(f"{kind}: --selfcheck without the updater's variable exits 2 and prints nothing",
          f.get("rc") == "2" and text(f"{kind}-sc-noenv", "stdout") == "")
    f = facts(f"{kind}-sc-env")
    out = text(f"{kind}-sc-env", "stdout")
    try:
        doc = json.loads(out)
    except ValueError:
        doc = None
    atype = "bash" if kind == "sh" else "python"
    check(f"{kind}: --selfcheck prints one line of JSON with agent_type and agent_version",
          f.get("rc") == "0" and out.count("\n") == 1 and isinstance(doc, dict)
          and doc.get("agent_type") == atype and doc.get("agent_version") == cur)
    check(f"{kind}: --selfcheck carries a full payload",
          isinstance(doc, dict) and isinstance(doc.get("payload"), dict)
          and doc["payload"].get("version") == cur and len(doc["payload"]) > 40
          and doc["payload"].get("agent_key") == "")
    agent_file = "agent.sh" if kind == "sh" else "agent.py"
    check(f"{kind}: --selfcheck writes nothing beside the agent",
          sorted(f.get("files", "").split()) == sorted([agent_file, "agent.cfg"]))

    # --- Self-update ----------------------------------------------------------
    f = facts(f"{kind}-upd-good-1")
    reps, _ = posts(f"{kind}-upd-good-1")
    check(f"{kind}: a good update is installed", f.get("agent_sha") == orig.get("good_sha") and f.get("agent_version") == "9.9.9")
    check(f"{kind}: ... the previous version is kept as .prev", f.get("prev_sha") == orig.get("orig_sha"))
    check(f"{kind}: ... on probation from the swap", f.get("probation", "").split()[:2] == ["9.9.9", cur]
          and f.get("probation", "").split()[3:] == ["0", "0"])
    check(f"{kind}: ... and no .new is left", f.get("new_exists") == "0")
    check(f"{kind}: ... with the mode of the file it replaced (0750)", f.get("mode") == "750")
    f = facts(f"{kind}-upd-good-2")
    reps, _ = posts(f"{kind}-upd-good-2")
    check(f"{kind}: the new version reports and ends its probation",
          reps == [cur, "9.9.9"] and f.get("probation") == "" and f.get("last_ok", "").startswith("9.9.9 "))

    for case, why in (("sha", "Checksum"), ("nosentinel", "bk-agent-end"), ("truncated", "bk-agent-end"),
                      ("badselfcheck", "samokontrol"), ("older", None), ("same", None), ("space", "místo")):
        f = facts(f"{kind}-upd-{case}")
        log = text(f"{kind}-upd-{case}", "log")
        check(f"{kind}: update refused ({case}): the agent is byte-identical",
              f.get("agent_sha") == orig.get("orig_sha"))
        check(f"{kind}: update refused ({case}): no .new, .prev or probation left",
              f.get("new_exists") == "0" and f.get("prev_sha") == "none" and f.get("probation") == "")
        if why:
            check(f"{kind}: update refused ({case}): the log says why", why in log and "Aktualizace zrušena" in log)
        else:
            check(f"{kind}: update refused ({case}): not even downloaded",
                  text(f"{kind}-upd-{case}", "gets").strip() == "")
    f = facts(f"{kind}-upd-nosentinel")
    check(f"{kind}: a file refused for its bytes is remembered and not downloaded again",
          f.get("refused", "").split()[:1] != [] and text(f"{kind}-upd-nosentinel", "gets").count("/files/") == 1
          and text(f"{kind}-upd-nosentinel", "log").count("Aktualizace zrušena") == 1)
    if kind == "sh":
        f = facts("sh-upd-nopython")
        check("sh: without python3 a good update still installs (fallback check of the self-check line)",
              f.get("agent_sha") == orig.get("good_sha") and f.get("probation", "").startswith("9.9.9 "))
    if kind == "sh":
        f = facts("sh-upd-warmcache")
        t = dict(l.split("=", 1) for l in text("sh-upd-warmcache", "time").split() if "=" in l)
        check("sh: with a warm heavy cache the self-check runs no SMART - hung disks do not refuse the update",
              f.get("agent_sha") == orig.get("good_sha") and t.get("smartctl_calls") == "0"
              and t.get("secs", "999").isdigit() and int(t.get("secs", "999")) < 45)
    f = facts(f"{kind}-upd-sha")
    check(f"{kind}: a checksum mismatch is not remembered (it may be the transfer)", f.get("refused") == "")
    check(f"{kind}: update refused (space): checked before the download",
          text(f"{kind}-upd-space", "gets").strip() == "")

    # --- Rollback -------------------------------------------------------------
    first = facts(f"{kind}-rb-rejected-1")
    check(f"{kind}: rollback case: the refused version installs first",
          first.get("agent_version") == "9.9.8" and first.get("prev_sha") == orig.get("orig_sha"))
    f4 = facts(f"{kind}-rb-rejected-4")
    check(f"{kind}: rollback case: three refusals are counted",
          f4.get("probation", "").split()[3:] == ["3", "3"] and f4.get("agent_version") == "9.9.8")
    f5 = facts(f"{kind}-rb-rejected-5")
    reps, _ = posts(f"{kind}-rb-rejected-5")
    check(f"{kind}: rollback case: the previous version comes back, byte-identical",
          f5.get("agent_sha") == orig.get("orig_sha") and f5.get("probation") == "" and f5.get("prev_sha") == "none")
    check(f"{kind}: rollback case: the restored version reports in the same run",
          reps == [cur, "9.9.8", "9.9.8", "9.9.8", cur])
    check(f"{kind}: rollback case: the rolled-back file is remembered",
          f5.get("refused", "").split()[:1] == [orig.get("refused_sha")])
    check(f"{kind}: rollback case: the log names the rollback", "předchozí verze" in text(f"{kind}-rb-rejected-5", "log"))
    f6 = facts(f"{kind}-rb-rejected-6")
    reps, _ = posts(f"{kind}-rb-rejected-6")
    check(f"{kind}: rollback case: the same offer is not reinstalled",
          f6.get("agent_sha") == orig.get("orig_sha") and reps[-1] == cur
          and text(f"{kind}-rb-rejected-6", "gets").count("/files/") == 1)

    f = facts(f"{kind}-rb-runs")
    reps, _ = posts(f"{kind}-rb-runs")
    check(f"{kind}: thirty runs without a report roll back too",
          f.get("agent_sha") == orig.get("orig_sha") and reps == [cur]
          and f.get("refused", "").split()[:1] == [orig.get("silent_sha")])

    f = facts(f"{kind}-rb-stale")
    reps, _ = posts(f"{kind}-rb-stale")
    check(f"{kind}: a probation file naming another version is dropped",
          f.get("probation") == "" and f.get("agent_sha") == orig.get("orig_sha") and reps == [cur])

# --- The shared rules, from agent.sh itself -----------------------------------
rules = text("sh-rules", "txt").splitlines()
accept = ["nginx", "nginx.service", "openvpn@server", "MSSQL$SQLEXPRESS", "_x", "a-b.c", "9", "a" * 128]
refuse = ["", "../x", ".hidden", "-H", "a b", "a/b", "a\\b", "a:b", "a;id", "$(id)", "a" * 129]
check("sh: service-name rule accepts " + ", ".join(n for n in accept if len(n) < 20) + ", 128 chars",
      all(f"svc ok {n}" in rules for n in accept))
check("sh: service-name rule refuses traversal, leading dot/dash, separators, 129 chars",
      all(f"svc refused {n}".rstrip() in [r.rstrip() for r in rules] for n in refuse))
newer = ["0.1.4 0.1.3", "0.1.10 0.1.9", "1.0 0.9.9", "0.2 0.1.99", "1.0.1 1.0"]
notnewer = ["0.1.3 0.1.3", "0.1.2 0.1.3", "1.0 1.0.0", "0.1.4-rc1 0.1.3", "0.1..4 0.1.3", ".1 0.0", "abc 0.1"]
check("sh: version order: only strictly newer dotted numbers pass",
      all(f"ver newer {p}" in rules for p in newer)
      and all(f"ver notnewer {p}" in rules for p in notnewer))

print(f"{'all passed' if not failed else str(len(failed)) + ' failed'}")
sys.exit(1 if failed else 0)

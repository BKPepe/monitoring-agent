#!/usr/bin/env python3
"""A stand-in for agent_api.php, for the security cases of the Linux agents
(run-security-cases.sh). It answers a report the way the real server does -
compact JSON, a signed `pending_action`, the update offer - from a scenario
file the case writes before each agent run, and serves update files.

    fake_api.py DIR PORT

DIR/scenario.json   read on every request:
  status         HTTP status for a report (default 200)
  fail_versions  {"9.9.8": 400}: reports carrying this version get that status
  action         pending action; "timestamp" "now" = the current time, an int
                 or a string is sent as given, and "raw_timestamp" is spliced
                 into the body verbatim (not JSON - what a forged answer can
                 carry). Signed with "key" over action|ts|nonce, the real
                 server's string, unless "signature" is given.
  update         {"agent_type", "version", "file", "sha"?, "force"?}: the
                 offer, only to that agent type; "sha" defaults to the file's
                 real SHA-256.
DIR/posts.jsonl     every POST body, one per line (the assertions read it)
DIR/gets.log        every GET path (was the update even downloaded?)
DIR/files/NAME      served at GET /files/NAME
"""
import hashlib
import hmac
import http.server
import json
import os
import sys
import time

ROOT = sys.argv[1]
PORT = int(sys.argv[2])
RAW_MARK = "__BK_RAW_TIMESTAMP__"


def scenario():
    try:
        with open(os.path.join(ROOT, "scenario.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, text, ctype="application/json"):
        data = text.encode("utf-8") if isinstance(text, str) else text
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        with open(os.path.join(ROOT, "gets.log"), "a") as f:
            f.write(self.path + "\n")
        name = os.path.basename(self.path)
        path = os.path.join(ROOT, "files", name)
        if not self.path.startswith("/files/") or not os.path.isfile(path):
            self.reply(404, '{"success":false}')
            return
        with open(path, "rb") as f:
            self.reply(200, f.read(), "application/octet-stream")

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        with open(os.path.join(ROOT, "posts.jsonl"), "ab") as f:
            f.write(body.replace(b"\n", b" ") + b"\n")
        try:
            doc = json.loads(body)
        except ValueError:
            self.reply(400, '{"success":false,"message":"invalid JSON"}')
            return
        if not isinstance(doc, dict):
            self.reply(400, '{"success":false}')
            return
        if "action_result" in doc:
            self.reply(200, '{"success":true}')
            return

        scen = scenario()
        status = int(scen.get("status", 200))
        status = int(scen.get("fail_versions", {}).get(str(doc.get("version")), status))
        if status != 200:
            self.reply(status, '{"success":false,"message":"rejected by the fake server"}')
            return

        resp = {"success": True, "message": "ok"}
        raw_ts = None
        act = scen.get("action")
        if act:
            ts = act.get("timestamp", "now")
            if ts == "now":
                ts = int(time.time())
            if "raw_timestamp" in act:
                raw_ts = act["raw_timestamp"]
                ts_text = raw_ts
                ts = RAW_MARK
            else:
                ts_text = str(ts)
            pending = {
                "action_id": act.get("action_id", 1),
                "action": act["action"],
                "timestamp": ts,
                "nonce": act.get("nonce", "a1b2c3d4e5f60718"),
            }
            msg = f"action={pending['action']}|ts={ts_text}|nonce={pending['nonce']}"
            pending["signature"] = act.get("signature") or hmac.new(
                act["key"].encode(), msg.encode(), hashlib.sha256).hexdigest()
            if "service_name" in act:
                pending["service_name"] = act["service_name"]
            resp["pending_action"] = pending

        upd = scen.get("update")
        if upd and upd.get("agent_type") == doc.get("agent_type"):
            path = os.path.join(ROOT, "files", upd["file"])
            with open(path, "rb") as f:
                real_sha = hashlib.sha256(f.read()).hexdigest()
            resp["latest_version"] = upd["version"]
            # The real server offers whatever differs (`!==`), older included;
            # "force" offers even the running version, to test the agent's
            # own direction check.
            resp["update_available"] = upd.get("force", False) or upd["version"] != doc.get("version")
            if resp["update_available"]:
                resp["update_url"] = f"http://127.0.0.1:{PORT}/files/{upd['file']}"
                resp["update_sha256"] = upd.get("sha") or real_sha

        text = json.dumps(resp, separators=(",", ":"))
        if raw_ts is not None:
            text = text.replace(f'"{RAW_MARK}"', raw_ts)
        self.reply(200, text)


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()

#!/usr/bin/env python3
"""Unit tests for agent.py's security rules: the digits gate, the shared
service-name rule, the single-use nonce store, the version order, the
end-of-file sentinel, the --selfcheck contract, the self-update swap and the
probation rollback. Every test imports a fresh copy of agent.py from a
temporary directory, so the markers it writes next to "itself" stay there.

    python3 -m unittest discover -s tests -p 'test_agent_py.py' -v

BK_AGENT_PY points at another agent.py (the container run uses it).
The end-to-end cases against a fake server are in linux/run-security-cases.sh.
"""
import hashlib
import hmac
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import time
import types
import unittest
import unittest.mock
import uuid

AGENT_SRC = os.environ.get("BK_AGENT_PY") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vps-agent", "agent.py")


def load_agent(directory):
    """A copy of agent.py in `directory`, imported as its own module."""
    path = os.path.join(directory, "agent.py")
    shutil.copy(AGENT_SRC, path)
    spec = importlib.util.spec_from_file_location("bk_agent_" + uuid.uuid4().hex, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.VERBOSE = False
    return mod


class AgentTestCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="bk-agent-test.")
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.agent = load_agent(self.dir)


class Rules(AgentTestCase):
    def test_service_name_rule(self):
        ok = ["nginx", "nginx.service", "openvpn@server", "MSSQL$SQLEXPRESS", "_x", "a-b.c", "9", "a" * 128]
        bad = ["", "../x", ".hidden", "-H", "a b", "a/b", "a\\b", "a:b", "a;id", "$(id)", "a" * 129, None, 5, "nginéx"]
        for name in ok:
            self.assertTrue(self.agent.valid_service_name(name), name)
        for name in bad:
            self.assertFalse(self.agent.valid_service_name(name), repr(name))

    def test_only_service_units_restart(self):
        # A target or a mount would turn restart_service into a system-wide
        # action; systemctl adds ".service" to a name without a unit suffix.
        for name in ["nginx", "nginx.service", "php8.2-fpm", "openvpn@server", "a-b.c"]:
            self.assertTrue(self.agent.service_unit_ok(name), name)
        for name in ["poweroff.target", "emergency.target", "getty@tty1.target", "home.mount", "x.automount",
                     "docker.socket", "dev-sda.device", "swapfile.swap", "x.path", "x.timer", "user.slice", "x.scope"]:
            self.assertFalse(self.agent.service_unit_ok(name), name)

    def test_digits_gate(self):
        d = self.agent._digits
        self.assertEqual(d(1790000000), 1790000000)
        self.assertEqual(d("1790000000"), 1790000000)
        self.assertEqual(d("0123"), 123)
        for value in (True, False, None, -1, 1.5, "12a", "", " 12", "1e9", "１２", 10 ** 18, "9" * 19, [1], {"a": 1}):
            self.assertIsNone(d(value), repr(value))

    def test_version_order(self):
        newer = [("0.1.4", "0.1.3"), ("0.1.10", "0.1.9"), ("1.0", "0.9.9"), ("0.2", "0.1.99"), ("1.0.1", "1.0")]
        not_newer = [("0.1.3", "0.1.3"), ("0.1.2", "0.1.3"), ("1.0", "1.0.0"), ("1.0.0", "1.0"), ("0.1.4-rc1", "0.1.3"),
                     ("0.1..4", "0.1.3"), (".1", "0.0"), ("abc", "0.1"), (None, "0.1"), ("", "0.1"), ("0.1.4", "x")]
        for a, b in newer:
            self.assertTrue(self.agent._version_newer(a, b), (a, b))
        for a, b in not_newer:
            self.assertFalse(self.agent._version_newer(a, b), (a, b))

    def test_sentinel(self):
        ok = self.agent._sentinel_ok
        self.assertTrue(ok(b"x = 1\n# bk-agent-end 0.1.4\n", "0.1.4"))
        self.assertTrue(ok(b"x = 1\n# bk-agent-end 0.1.4", "0.1.4"))
        self.assertFalse(ok(b"x = 1\n# bk-agent-end 0.1.4\n\n", "0.1.4"))
        self.assertFalse(ok(b"x = 1\n# bk-agent-end 0.1.3\n", "0.1.4"))
        self.assertFalse(ok(b"x = 1\n# bk-agent-end 0.1.4 extra\n", "0.1.4"))
        self.assertFalse(ok(b"x = 1\ny = 2\n", "0.1.4"))

    def test_shipped_file_ends_with_its_own_sentinel(self):
        with open(AGENT_SRC, "rb") as f:
            self.assertTrue(self.agent._sentinel_ok(f.read(), self.agent.AGENT_VERSION))

    def test_selfcheck_contract(self):
        ok = self.agent._selfcheck_ok
        line = json.dumps({"agent_type": "python", "agent_version": "0.1.4",
                           "payload": {"agent_type": "python", "version": "0.1.4"}}) + "\n"
        self.assertTrue(ok(line, "0.1.4"))
        self.assertTrue(ok('{"agent_type":"python","agent_version":"0.1.4"}\n', "0.1.4"))
        self.assertFalse(ok(line, "0.1.5"))
        self.assertFalse(ok(line.rstrip("\n"), "0.1.4"))
        self.assertFalse(ok(line + line, "0.1.4"))
        self.assertFalse(ok('{"agent_type":"bash","agent_version":"0.1.4"}\n', "0.1.4"))
        self.assertFalse(ok('{"agent_type":"python","agent_version":"0.1.4","payload":{"version":"0.1.3"}}\n', "0.1.4"))
        self.assertFalse(ok('{"agent_type":"python","agent_version":"0.1.4"\n', "0.1.4"))
        self.assertFalse(ok('["python","0.1.4"]\n', "0.1.4"))


class NonceGate(AgentTestCase):
    def gate(self, nonce="abc123", act_type="restart_service", svc="nginx", now=None):
        return self.agent._action_gate(act_type, nonce, svc, int(time.time()) if now is None else now)

    def test_a_nonce_is_single_use(self):
        self.assertIsNone(self.gate())
        self.assertIn("už byl použit", self.gate())
        self.assertIsNone(self.gate(nonce="other1"))

    def test_an_old_nonce_is_forgotten_after_sixty_seconds(self):
        now = int(time.time())
        self.assertIsNone(self.gate(now=now - 61))
        self.assertIsNone(self.gate(now=now))
        with open(self.agent.NONCE_FILE) as f:
            self.assertEqual(len(f.read().split("\n")), 2)

    def test_a_nonce_that_cannot_be_stored_refuses(self):
        self.agent.NONCE_FILE = os.path.join(self.dir, "missing-dir", "nonces")
        self.assertIn("nejde uložit", self.gate())

    def test_a_nonce_store_that_cannot_be_read_refuses(self):
        os.mkdir(self.agent.NONCE_FILE)
        self.assertIn("nejde přečíst", self.gate())

    def test_nonce_type_and_service_checks(self):
        self.assertIn("nonce", self.gate(nonce="ab-12"))
        self.assertIn("nonce", self.gate(nonce=""))
        self.assertIn("nonce", self.gate(nonce=None))
        self.assertIn("typ", self.gate(nonce="n2", act_type="restart,service"))
        self.assertIn("ALLOWED_ACTIONS", self.gate(nonce="n3", act_type="restart_wan"))
        self.assertIn("název služby", self.gate(nonce="n4", svc="../../tmp/x"))
        self.assertIn("název služby", self.gate(nonce="n5", svc="-H"))
        self.assertIn("není služba", self.gate(nonce="n6", svc="poweroff.target"))


class RemoteAction(AgentTestCase):
    KEY = "k-0123456789"

    def setUp(self):
        super().setUp()
        self.agent.AGENT_KEY = self.KEY
        self.results = []
        self.calls = []
        self.agent.send_action_result = lambda i, s, m: self.results.append((i, s, m))
        self.agent.log_message = lambda msg: None
        real = self.agent.subprocess

        def fake_call(cmd, **kwargs):
            self.calls.append(cmd)
            return 0
        self.agent.subprocess = types.SimpleNamespace(call=fake_call, DEVNULL=real.DEVNULL,
                                                      TimeoutExpired=real.TimeoutExpired)

    def body(self, ts=None, nonce="n0nce1", action="restart_service", svc="nginx", action_id=7, sig=None, raw=None):
        ts = int(time.time()) if ts is None else ts
        msg = f"action={action}|ts={ts}|nonce={nonce}"
        pending = {"action_id": action_id, "action": action, "timestamp": ts, "nonce": nonce,
                   "signature": sig or hmac.new(self.KEY.encode(), msg.encode(), hashlib.sha256).hexdigest(),
                   "service_name": svc}
        return json.dumps({"success": True, "pending_action": pending})

    def test_valid_action_runs_once_and_a_replay_is_refused(self):
        body = self.body()
        self.agent.handle_remote_action(body)
        self.agent.handle_remote_action(body)
        self.assertEqual(self.calls, [["systemctl", "restart", "nginx"]])
        self.assertEqual([r[1] for r in self.results], ["executed", "failed"])
        self.assertIn("už byl použit", self.results[1][2])

    def test_non_numeric_timestamp_or_id_is_ignored(self):
        for body in (self.body(ts="12a"), self.body(ts=True), self.body(action_id="7;"), self.body(action_id=True),
                     self.body(ts="1e9"), '{"pending_action":{"action_id":1,"timestamp":{"a":1}}}'):
            self.agent.handle_remote_action(body)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.results, [])

    def test_a_string_timestamp_of_digits_is_signed_as_sent(self):
        self.agent.handle_remote_action(self.body(ts=str(int(time.time()))))
        self.assertEqual([r[1] for r in self.results], ["executed"])

    def test_bad_service_name_is_refused_after_the_signature(self):
        self.agent.handle_remote_action(self.body(svc="../../tmp/pwn"))
        self.assertEqual(self.calls, [])
        self.assertEqual(self.results[0][1], "failed")
        self.assertIn("název služby", self.results[0][2])

    def test_a_systemd_target_is_refused_after_the_signature(self):
        self.agent.handle_remote_action(self.body(svc="emergency.target"))
        self.assertEqual(self.calls, [])
        self.assertEqual(self.results[0][1], "failed")
        self.assertIn("není služba", self.results[0][2])

    def test_bad_signature_burns_no_nonce(self):
        self.agent.handle_remote_action(self.body(sig="00ff"))
        self.assertEqual(self.calls, [])
        self.assertIn("HMAC", self.results[0][2])
        self.assertFalse(os.path.exists(self.agent.NONCE_FILE))

    def test_non_ascii_signature_does_not_crash(self):
        self.agent.handle_remote_action(self.body(sig="é" * 64))
        self.assertIn("HMAC", self.results[0][2])

    def test_expired_action_is_refused(self):
        self.agent.handle_remote_action(self.body(ts=int(time.time()) - 120))
        self.assertEqual(self.calls, [])
        self.assertIn("Vypršela", self.results[0][2])

    def test_no_pending_action_is_silent(self):
        self.agent.handle_remote_action('{"success":true}')
        self.agent.handle_remote_action('not json')
        self.agent.handle_remote_action('[1,2]')
        self.assertEqual((self.calls, self.results), ([], []))


def fake_agent_source(version, agent_type="python", selfcheck_version=None, extra=""):
    """A tiny stand-in for a downloaded agent: it answers --selfcheck the way
    the real one does (or wrongly, for the refusal tests) and carries the
    end sentinel."""
    sc_version = version if selfcheck_version is None else selfcheck_version
    return (
        "import json, os, sys\n"
        f"AGENT_VERSION = \"{version}\"\n"
        f"{extra}"
        "if '--selfcheck' in sys.argv and os.environ.get('BK_UPDATE_SELFCHECK') == '1':\n"
        f"    print(json.dumps({{'agent_type': '{agent_type}', 'agent_version': '{sc_version}',"
        f" 'payload': {{'agent_type': '{agent_type}', 'version': '{sc_version}'}}}}))\n"
        "    sys.exit(0)\n"
        f"# bk-agent-end {version}\n"
    ).encode()


class SelfUpdate(AgentTestCase):
    def setUp(self):
        super().setUp()
        self.logs = []
        self.agent.log_message = self.logs.append
        self.agent.log_debug = self.logs.append
        self.served = None
        self.downloads = 0

        def urlopen(url, timeout=None):
            self.downloads += 1
            return io.BytesIO(self.served)
        self.agent.urllib = types.SimpleNamespace(request=types.SimpleNamespace(urlopen=urlopen))
        with open(self.agent.SELF_PATH, "rb") as f:
            self.original = f.read()

    def offer(self, source, version, sha=None):
        self.served = source
        return {"update_available": True, "latest_version": version,
                "update_url": "http://example.invalid/agent.py",
                "update_sha256": sha or hashlib.sha256(source).hexdigest()}

    def assert_untouched(self):
        with open(self.agent.SELF_PATH, "rb") as f:
            self.assertEqual(f.read(), self.original)
        for suffix in (".new", ".prev", ".probation"):
            self.assertFalse(os.path.exists(self.agent.SELF_PATH + suffix), suffix)

    def test_good_update_swaps_keeps_prev_and_starts_probation(self):
        src = fake_agent_source("9.9.9")
        self.assertTrue(self.agent.self_update(self.offer(src, "9.9.9")))
        with open(self.agent.SELF_PATH, "rb") as f:
            self.assertEqual(f.read(), src)
        with open(self.agent.SELF_PATH + ".prev", "rb") as f:
            self.assertEqual(f.read(), self.original)
        with open(self.agent.PROBATION_FILE) as f:
            self.assertEqual(f.read().split(), ["9.9.9", self.agent.AGENT_VERSION, hashlib.sha256(src).hexdigest(), "0", "0"])
        self.assertFalse(os.path.exists(self.agent.SELF_PATH + ".new"))

    def test_older_and_same_versions_are_not_even_downloaded(self):
        for version in ("0.0.1", self.agent.AGENT_VERSION, "0.1.4-rc1"):
            self.assertFalse(self.agent.self_update(self.offer(fake_agent_source(version), version)))
        self.assertEqual(self.downloads, 0)
        self.assert_untouched()

    def test_sha_mismatch_is_refused(self):
        self.assertFalse(self.agent.self_update(self.offer(fake_agent_source("9.9.9"), "9.9.9", sha="0" * 64)))
        self.assert_untouched()

    def test_missing_or_wrong_sentinel_is_refused(self):
        src = fake_agent_source("9.9.9")
        cut = src[:src.rindex(b"# bk-agent-end")]
        self.assertFalse(self.agent.self_update(self.offer(cut, "9.9.9")))
        self.assertFalse(self.agent.self_update(self.offer(fake_agent_source("9.9.8"), "9.9.9")))
        self.assert_untouched()

    def test_syntax_error_is_refused(self):
        self.assertFalse(self.agent.self_update(self.offer(fake_agent_source("9.9.9", extra="def (:\n"), "9.9.9")))
        self.assert_untouched()

    def test_failing_selfcheck_is_refused(self):
        # The historic NameError: compiles, dies when run.
        crash = fake_agent_source("9.9.9", extra="name_that_does_not_exist\n")
        wrong_type = fake_agent_source("9.9.9", agent_type="bash")
        wrong_version = fake_agent_source("9.9.9", selfcheck_version="9.9.8")
        for src in (crash, wrong_type, wrong_version):
            self.assertFalse(self.agent.self_update(self.offer(src, "9.9.9")))
            self.assert_untouched()
        self.assertTrue(any("samokontrol" in m for m in self.logs))

    def test_selfcheck_is_bounded_by_a_timeout(self):
        self.agent.SELFCHECK_TIMEOUT_S = 1
        slow = fake_agent_source("9.9.9", extra="import time\ntime.sleep(30)\n")
        start = time.time()
        self.assertFalse(self.agent.self_update(self.offer(slow, "9.9.9")))
        self.assertLess(time.time() - start, 10)
        self.assert_untouched()
        self.assertTrue(any("vypršel čas" in m for m in self.logs))

    def test_a_refused_file_is_never_downloaded_again(self):
        cut = fake_agent_source("9.9.9")[:-5]
        self.assertFalse(self.agent.self_update(self.offer(cut, "9.9.9")))
        self.assertFalse(self.agent.self_update(self.offer(cut, "9.9.9")))
        self.assertEqual(self.downloads, 1)
        with open(self.agent.REFUSED_FILE) as f:
            self.assertEqual(f.read().split()[0], hashlib.sha256(cut).hexdigest())
        # Two days on (a fake clock): the verdict has no expiry.
        with unittest.mock.patch("time.time", return_value=time.time() + 2 * 86400):
            self.assertFalse(self.agent.self_update(self.offer(cut, "9.9.9")))
        self.assertEqual(self.downloads, 1)

    def test_a_timed_out_selfcheck_is_remembered_too(self):
        self.agent.SELFCHECK_TIMEOUT_S = 1
        slow = fake_agent_source("9.9.9", extra="import time\ntime.sleep(30)\n")
        self.assertFalse(self.agent.self_update(self.offer(slow, "9.9.9")))
        self.assertFalse(self.agent.self_update(self.offer(slow, "9.9.9")))
        self.assertEqual(self.downloads, 1)
        self.assertTrue(self.agent._is_refused(hashlib.sha256(slow).hexdigest()))

    def test_a_sha_mismatch_is_not_remembered(self):
        src = fake_agent_source("9.9.9")
        self.assertFalse(self.agent.self_update(self.offer(src, "9.9.9", sha="0" * 64)))
        self.assertFalse(os.path.exists(self.agent.REFUSED_FILE))
        self.assertTrue(self.agent.self_update(self.offer(src, "9.9.9")))

    def test_a_rolled_back_file_is_never_reinstalled(self):
        src = fake_agent_source("9.9.9")
        sha = hashlib.sha256(src).hexdigest()
        with open(self.agent.REFUSED_FILE, "w") as f:
            f.write(f"{sha} {int(time.time()) - 3600}\n")
        self.assertFalse(self.agent.self_update(self.offer(src, "9.9.9")))
        # A verdict from two days ago (the old limit was one day), and the
        # same with the clock moved on instead.
        with open(self.agent.REFUSED_FILE, "w") as f:
            f.write(f"{sha} {int(time.time()) - 2 * 86400}\n")
        self.assertFalse(self.agent.self_update(self.offer(src, "9.9.9")))
        with unittest.mock.patch("time.time", return_value=time.time() + 30 * 86400):
            self.assertFalse(self.agent.self_update(self.offer(src, "9.9.9")))
        self.assertEqual(self.downloads, 0)
        self.assert_untouched()

    def test_a_new_sha_of_the_same_version_is_taken(self):
        bad = fake_agent_source("9.9.9")
        self.agent._refuse_sha(hashlib.sha256(bad).hexdigest())
        fixed = fake_agent_source("9.9.9", extra="# republished with a fix\n")
        self.assertTrue(self.agent.self_update(self.offer(fixed, "9.9.9")))
        with open(self.agent.SELF_PATH, "rb") as f:
            self.assertEqual(f.read(), fixed)
        self.assertTrue(self.agent._is_refused(hashlib.sha256(bad).hexdigest()))

    def test_the_list_keeps_the_last_eight_newest_last(self):
        shas = [hashlib.sha256(str(i).encode()).hexdigest() for i in range(10)]
        for sha in shas:
            self.agent._refuse_sha(sha)
        def listed():
            with open(self.agent.REFUSED_FILE) as f:
                return [line.split()[0] for line in f.read().splitlines()]
        self.assertEqual(listed(), shas[2:])
        self.assertFalse(self.agent._is_refused(shas[0]))
        self.assertTrue(self.agent._is_refused(shas[2]))
        # Refused again: moved to the end, never twice.
        self.agent._refuse_sha(shas[4])
        self.assertEqual(listed(), shas[2:4] + shas[5:] + [shas[4]])
        # Not a sha: nothing written, nothing matched.
        self.agent._refuse_sha("not-a-sha")
        self.agent._refuse_sha(None)
        self.assertEqual(len(listed()), 8)
        self.assertFalse(self.agent._is_refused(""))
        self.assertFalse(self.agent._is_refused(None))

    def test_a_damaged_list_refuses_only_exact_shas(self):
        sha = hashlib.sha256(b"x").hexdigest()
        with open(self.agent.REFUSED_FILE, "wb") as f:
            f.write(b"garbage \xff\xfe line\n\n   \n" + sha.encode() + b"\n")
        self.assertTrue(self.agent._is_refused(sha))
        self.assertFalse(self.agent._is_refused("garbage"))
        self.agent._refuse_sha(hashlib.sha256(b"y").hexdigest())
        self.assertTrue(self.agent._is_refused(sha))


class Probation(AgentTestCase):
    def setUp(self):
        super().setUp()
        self.logs = []
        self.agent.log_message = self.logs.append
        self.execs = []

        class Exec(Exception):
            pass
        self.Exec = Exec

        def execv(path, args):
            self.execs.append(args)
            raise Exec()
        self.agent.os = types.SimpleNamespace(**{k: getattr(os, k) for k in dir(os) if not k.startswith("__")})
        self.agent.os.execv = execv
        self.prev_source = fake_agent_source("0.0.9")
        with open(self.agent.SELF_PATH + ".prev", "wb") as f:
            f.write(self.prev_source)

    def write(self, line):
        with open(self.agent.PROBATION_FILE, "w") as f:
            f.write(line + "\n")

    def read(self):
        with open(self.agent.PROBATION_FILE) as f:
            return f.read().split()

    def test_no_probation_file_is_no_probation(self):
        self.assertIsNone(self.agent._probation_check())

    def test_a_file_naming_another_version_is_dropped(self):
        self.write("9.9.6 0.0.9 abc 29 2")
        self.assertIsNone(self.agent._probation_check())
        self.assertFalse(os.path.exists(self.agent.PROBATION_FILE))

    def test_runs_are_counted_under_the_limits(self):
        v = self.agent.AGENT_VERSION
        self.write(f"{v} 0.0.9 abc 0 2")
        pb = self.agent._probation_check()
        self.assertEqual((pb["runs"], pb["rejected"]), (1, 2))
        self.assertEqual(self.read(), [v, "0.0.9", "abc", "1", "2"])

    def test_three_refusals_roll_back(self):
        v = self.agent.AGENT_VERSION
        self.write(f"{v} 0.0.9 abcdef 4 3")
        with self.assertRaises(self.Exec):
            self.agent._probation_check()
        with open(self.agent.SELF_PATH, "rb") as f:
            self.assertEqual(f.read(), self.prev_source)
        self.assertFalse(os.path.exists(self.agent.SELF_PATH + ".prev"))
        self.assertFalse(os.path.exists(self.agent.PROBATION_FILE))
        with open(self.agent.REFUSED_FILE) as f:
            self.assertEqual(f.read().split()[0], "abcdef")
        self.assertTrue(any("se už znovu nestáhne" in m for m in self.logs))
        self.assertEqual(self.execs[0][1], self.agent.SELF_PATH)

    def test_thirty_runs_without_a_report_roll_back(self):
        self.write(f"{self.agent.AGENT_VERSION} 0.0.9 abcdef 30 0")
        with self.assertRaises(self.Exec):
            self.agent._probation_check()

    def test_no_usable_prev_means_no_rollback(self):
        with open(self.agent.SELF_PATH, "rb") as f:
            current = f.read()
        with open(self.agent.SELF_PATH + ".prev", "wb") as f:
            f.write(b"def (:\n")
        self.write(f"{self.agent.AGENT_VERSION} 0.0.9 abcdef 30 0")
        self.assertIsNone(self.agent._probation_check())
        self.assertEqual(self.execs, [])
        with open(self.agent.SELF_PATH, "rb") as f:
            self.assertEqual(f.read(), current)


class SelfcheckGate(unittest.TestCase):
    """The mode itself, run as the updater runs it."""

    def run_agent(self, env_extra):
        import subprocess
        d = tempfile.mkdtemp(prefix="bk-agent-sc.")
        self.addCleanup(shutil.rmtree, d, True)
        path = os.path.join(d, "agent.py")
        shutil.copy(AGENT_SRC, path)
        env = dict(os.environ, **env_extra)
        env.pop("STATUS_VERBOSE", None)
        proc = subprocess.run([sys.executable, path, "--selfcheck"], env=env, capture_output=True, text=True, timeout=120)
        return proc, sorted(os.listdir(d))

    def test_without_the_updater_variable_it_does_nothing(self):
        proc, files = self.run_agent({"BK_UPDATE_SELFCHECK": ""})
        self.assertEqual((proc.returncode, proc.stdout), (2, ""))
        self.assertEqual(files, ["agent.py"])

    def test_it_prints_one_contract_line_and_writes_nothing(self):
        proc, files = self.run_agent({"BK_UPDATE_SELFCHECK": "1"})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.count("\n"), 1)
        doc = json.loads(proc.stdout)
        self.assertEqual((doc["agent_type"], doc["payload"]["agent_type"]), ("python", "python"))
        self.assertEqual(doc["payload"]["agent_key"], "")
        self.assertEqual(files, ["agent.py"])


if __name__ == "__main__":
    unittest.main()

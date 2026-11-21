#!/bin/bash
# Runs inside the Debian container (see ../run_linux_e2e.sh): each agent
# twice, the second run under a busy `yes` so the CPU ranking has something
# to rank. --dry-run prints the payload and needs no key.
set -e
cp /work/agent/agent.sh /work/agent/agent.py /agent/
cp /harness/fake_ts3.py /agent/fake_ts3.py
cd /agent

# A stand-in TeamSpeak ServerQuery on 10011. Both Linux agents ask it, and
# until now nothing ever exercised that code at all - agent.sh talked to it
# over bash's socket redirection, which a hosting malware scanner treated as
# a reverse shell and quarantined the whole agent for.
python3 /agent/fake_ts3.py &
ts3_pid=$!
sleep 1
bash agent.sh --dry-run > /work/out/sh1.json 2>/work/out/sh1.err
python3 agent.py --dry-run > /work/out/py1.json 2>/work/out/py1.err
sleep 2
yes > /dev/null & yp=$!
sleep 1
bash agent.sh --dry-run > /work/out/sh2.json 2>/work/out/sh2.err
python3 agent.py --dry-run > /work/out/py2.json 2>/work/out/py2.err
kill "$yp"

# The same query once more with python3 made unusable, so the nc fallback is
# the one answering. Without this the second transport would ship untested.
# (The agents append the system directories to PATH only when missing, so a
# directory put first still wins.)
mkdir -p /agent/nopython
printf '#!/bin/sh\nexit 1\n' > /agent/nopython/python3
chmod +x /agent/nopython/python3
PATH="/agent/nopython:$PATH" bash agent.sh --dry-run > /work/out/sh3.json 2>/work/out/sh3.err

kill "$ts3_pid" 2>/dev/null || true
if grep -qi traceback /work/out/py1.err /work/out/py2.err; then cat /work/out/py2.err >&2; exit 1; fi

# cron's environment: PATH=/usr/bin:/bin and nothing else. A tool in an sbin
# directory - here a stand-in zerotier-cli, which Debian installs in
# /usr/sbin - has to be found there too, or every cron run reports null for
# what the manual test measured. Fresh directories, so both runs are first
# runs and compare like with like.
printf '#!/bin/sh\necho "200 listnetworks 8056c2e21c000001 home 02:aa:bb:cc:dd:ee OK PRIVATE ztabc 10.147.17.5/24"\n' > /usr/sbin/zerotier-cli
chmod +x /usr/sbin/zerotier-cli
for mode in i c; do
    mkdir -p "/cron/$mode"
    cp agent.sh agent.py "/cron/$mode/"
done
bash /cron/i/agent.sh --dry-run > /work/out/cron_sh_i.json 2>/work/out/cron_sh_i.err
env -i PATH=/usr/bin:/bin HOME=/root bash /cron/c/agent.sh --dry-run > /work/out/cron_sh_c.json 2>/work/out/cron_sh_c.err
python3 /cron/i/agent.py --dry-run > /work/out/cron_py_i.json 2>/work/out/cron_py_i.err
env -i PATH=/usr/bin:/bin HOME=/root python3 /cron/c/agent.py --dry-run > /work/out/cron_py_c.json 2>/work/out/cron_py_c.err
rm -f /usr/sbin/zerotier-cli

# agent.py's unit tests, on this image's Python.
BK_AGENT_PY=/agent/agent.py python3 -m unittest discover -s /work/tests -p 'test_agent_py.py' > /work/out/py_unit.txt 2>&1 \
    || { cat /work/out/py_unit.txt >&2; exit 1; }
tail -n 3 /work/out/py_unit.txt

# Remote actions, --selfcheck, self-update and rollback against a fake server.
bash /harness/run-security-cases.sh

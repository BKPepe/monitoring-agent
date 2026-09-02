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
mkdir -p /agent/nopython
printf '#!/bin/sh\nexit 1\n' > /agent/nopython/python3
chmod +x /agent/nopython/python3
PATH="/agent/nopython:$PATH" bash agent.sh --dry-run > /work/out/sh3.json 2>/work/out/sh3.err

kill "$ts3_pid" 2>/dev/null || true
if grep -qi traceback /work/out/py1.err /work/out/py2.err; then cat /work/out/py2.err >&2; exit 1; fi

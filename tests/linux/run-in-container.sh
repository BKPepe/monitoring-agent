#!/bin/bash
# Runs inside the Debian container (see ../run_linux_e2e.sh): each agent
# twice, the second run under a busy `yes` so the CPU ranking has something
# to rank. --dry-run prints the payload and needs no key.
set -e
cp /work/agent/agent.sh /work/agent/agent.py /agent/
cd /agent
bash agent.sh --dry-run > /work/out/sh1.json 2>/work/out/sh1.err
python3 agent.py --dry-run > /work/out/py1.json 2>/work/out/py1.err
sleep 2
yes > /dev/null & yp=$!
sleep 1
bash agent.sh --dry-run > /work/out/sh2.json 2>/work/out/sh2.err
python3 agent.py --dry-run > /work/out/py2.json 2>/work/out/py2.err
kill "$yp"
if grep -qi traceback /work/out/py1.err /work/out/py2.err; then cat /work/out/py2.err >&2; exit 1; fi

#!/bin/sh
# Runs inside a distro image (see ../run_linux_distros.sh): agent.sh and
# agent.py each twice with a plain --dry-run, 3 s apart so the second run has
# its deltas. No seam, no stub: the distro's own tools.
#
#   run-in-container.sh DISTRO - writes /work/out/DISTRO_{sh,py}{1,2}.{json,err,rc}
#   and DISTRO_env.txt
set -u
d=$1
OUT=/work/out
mkdir -p /opt/bk "$OUT"
cp /work/agent/agent.sh /work/agent/agent.py /opt/bk/
cd /opt/bk || exit 1
{
    sed -n 's/^PRETTY_NAME=//p' /etc/os-release
    bash --version | head -n 1
    python3 --version
    echo "ps: $(readlink -f "$(command -v ps)")"
} > "$OUT/${d}_env.txt" 2>&1
sed 's/^/  /' "$OUT/${d}_env.txt"
for k in sh py; do
    for r in 1 2; do
        [ "$r" = 1 ] || sleep 3
        if [ "$k" = sh ]; then
            bash agent.sh --dry-run > "$OUT/${d}_$k$r.json" 2> "$OUT/${d}_$k$r.err"
        else
            python3 agent.py --dry-run > "$OUT/${d}_$k$r.json" 2> "$OUT/${d}_$k$r.err"
        fi
        echo "$?" > "$OUT/${d}_$k$r.rc"
        echo "  $k$r exit $(cat "$OUT/${d}_$k$r.rc")"
    done
done
exit 0

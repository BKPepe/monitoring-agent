#!/bin/sh
# The update server of the W1-B runs (run-in-container.sh copies this to
# /tmp/curlbin/curl and puts that directory in PATH for those runs only - in
# stubs/bin it would change which client every other run posts with). It
# answers the agent's download, `curl -fsS -m N --connect-timeout 10 -o FILE
# URL`, from /srv/upd/<last path part of URL>, and logs every such URL, so a
# run can prove it downloaded nothing. An unknown name is a 404 (curl -f: 22).
# With curl in PATH the agent asks it for the HiLink modem too: anything that
# is not http://upd.test/ is answered as unreachable and not logged - those
# runs are about the update, not the modem.
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        -m|--connect-timeout) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
case "$url" in http://upd.test/*) ;; *) exit 7 ;; esac
echo "$url" >> /work/out/upd_curl.log
src="/srv/upd/${url##*/}"
[ -n "$out" ] && [ -f "$src" ] || exit 22
cp "$src" "$out"

#!/bin/sh
# curl, uclient-fetch and wget for the R338 runs - real runs, no --dry-run,
# each client alone on PATH in its own directory (post-curl, post-uf,
# post-wget). Logs its argv, keeps a copy of the body FILE it was handed and
# that file's mode, and answers like the server: /tmp/post-resp.json to the
# report, {"status":"ok"} to an action result or the service checks.
# BK_POST_TAG names the run's files; the harness files the argv lines.
_me=${0##*/}
echo "$_me $*" >> /work/out/post_argv.log
_f=""; _prev=""
for _a; do
    case "$_a" in
        @*) _f=${_a#@} ;;
        --post-file=*) _f=${_a#--post-file=} ;;
    esac
    [ "$_prev" = "--post-file" ] && _f=$_a
    _prev=$_a
done
_n=0
while [ -e "/work/out/${BK_POST_TAG}_body_$_n.json" ]; do _n=$((_n + 1)); done
_resp='{"status":"ok"}'
if [ -n "$_f" ]; then
    cp "$_f" "/work/out/${BK_POST_TAG}_body_$_n.json"
    ls -l "$_f" | cut -c1-10 > "/work/out/${BK_POST_TAG}_mode_$_n.txt"
    case "$(cat "$_f")" in
        *'"service_check_results"'*|*'"action_result"'*) ;;
        *) _resp=$(cat /tmp/post-resp.json) ;;
    esac
fi
case "$_me" in
    curl) printf '%s\n200' "$_resp" ;;
    uclient-fetch) printf '%s\n' "$_resp" ;;
    wget) printf '%s\n' "$_resp"; echo '  HTTP/1.1 200 OK' >&2 ;;
esac
exit 0

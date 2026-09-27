#!/usr/bin/env bash
# agent.ps1 in a PowerShell 7 container: parse, BOM, sentinel and
# PSScriptAnalyzer's Windows PowerShell 5.1 compatibility rules, then the
# agent run against a local mock API - dry run, -SelfCheck, the remote-action
# gates (digits-only id/timestamp, service names, single-use nonce) and the
# self-update (sentinel, self-check, direction, swap, probation, rollback).
# Needs docker. Windows itself (5.1, CIM, services, ACLs) is not covered.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
. "$here/e2e_cleanup.sh"
name="${BK_E2E_CONTAINER:-bk-ps1-e2e-$$}"
trap 'bk_e2e_exit $? "$work" bk-ps1-e2e "$name"' EXIT
case "$(uname -m)" in
    x86_64|amd64) base="mcr.microsoft.com/powershell:7.4-ubuntu-22.04" ;;
    *) base="mcr.microsoft.com/powershell:7.4-azurelinux-3.0-arm64" ;;
esac
# A copy: an edit to the checkout while the tests run must not change the
# file under test half way.
mkdir -p "$work/src"
cp "$here/../vps-agent/agent.ps1" "$work/src/agent.ps1"
docker build -q --build-arg "BASE=${BK_PS1_BASE:-$base}" -t bk-ps1-e2e "$here/windows" >/dev/null
# As the calling user: it writes nothing outside /work, so nothing it leaves
# there is root's (HOME: pwsh keeps its caches there).
docker run --rm --name "$name" --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$work:/work" -v "$here/windows:/harness:ro" \
    bk-ps1-e2e bash /harness/run-in-container.sh

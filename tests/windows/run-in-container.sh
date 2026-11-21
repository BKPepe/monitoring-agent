#!/usr/bin/env bash
# Inside the container: the mock API in the background, then the tests.
set -u
mkdir -p /work/mock/files
pwsh -NoProfile -File /harness/mock_api.ps1 -Port 18080 -Dir /work/mock > /work/mock/mock.out 2>&1 &
mock=$!
for _ in $(seq 1 100); do [ -f /work/mock/ready ] && break; sleep 0.2; done
if [ ! -f /work/mock/ready ]; then
    echo "mock API did not start:"; cat /work/mock/mock.out
    exit 1
fi
pwsh -NoProfile -File /harness/agent_ps1_tests.ps1 -AgentSrc /work/src/agent.ps1 -Work /work
rc=$?
kill "$mock" 2>/dev/null
exit $rc

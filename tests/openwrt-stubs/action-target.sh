#!/bin/sh
# What a remote action ends up calling. The agent uses absolute paths
# (/sbin/ifdown, /sbin/reboot, /etc/init.d/<name>), so runs-g28.sh installs
# this file there; every call is one line in action_calls.log.
echo "$0 $*" >> /work/out/action_calls.log

#!/bin/sh
# What a remote action ends up calling. The agent uses absolute paths
# (/sbin/ifdown, /sbin/reboot, /etc/init.d/<name>), so runs-g28.sh installs
# this file there; every call is one line in action_calls.log.
echo "$0 $*" >> /work/out/action_calls.log
# ifup and ifdown answer an interface netifd does not know as the real
# script does: "Interface X not found", exit 0 (OpenWrt 24.10 and the
# snapshot). BK_STUB_IFACES names interfaces beyond wan, lan and lte.
case "${0##*/}" in
  ifup|ifdown)
    case " wan lan lte $BK_STUB_IFACES " in
      *" $1 "*) ;;
      *) echo "Interface $1 not found"; exit 0 ;;
    esac ;;
esac
# BK_STUB_ACTION_FAIL="name ...": these targets fail (exit 1), as a ubus
# call inside ifup does when netifd refuses it.
case " $BK_STUB_ACTION_FAIL " in *" ${0##*/} "*) exit 1 ;; esac

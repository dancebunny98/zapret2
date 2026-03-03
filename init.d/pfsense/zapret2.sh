#!/bin/sh
#
# pfSense / FreeBSD service helper for zapret2 (dvtws2)
# Place to /usr/local/etc/rc.d/zapret2.sh and chmod 755

ZDIR=${ZDIR:-/usr/local/etc/zapret2}
DVTWS2=${DVTWS2:-$ZDIR/nfq2/dvtws2}
DIVERT_PORT=${DIVERT_PORT:-990}
RULE_NUM=${RULE_NUM:-100}
DVTWS2_OPT=${DVTWS2_OPT:---lua-desync=multisplit}
PROC_NAME=dvtws2

load_module_if_needed()
{
	# $1 - module name
	kldstat -qm "$1" >/dev/null 2>&1 || kldload "$1" >/dev/null 2>&1
}

set_sysctl_if_exists()
{
	# $1 - key
	# $2 - value
	sysctl -qn "$1" >/dev/null 2>&1 && sysctl "$1=$2" >/dev/null 2>&1
}

prepare_pf_ipfw_hooks()
{
	# Older builds may expose these tunables, newer may not.
	set_sysctl_if_exists net.inet.ip.pfil.outbound ipfw,pf
	set_sysctl_if_exists net.inet.ip.pfil.inbound ipfw,pf
	set_sysctl_if_exists net.inet6.ip6.pfil.outbound ipfw,pf
	set_sysctl_if_exists net.inet6.ip6.pfil.inbound ipfw,pf

	# pfSense often needs pf toggle after ipfw/ipdivert enable.
	command -v pfctl >/dev/null 2>&1 && {
		pfctl -d >/dev/null 2>&1
		pfctl -e >/dev/null 2>&1
	}
}

ensure_ipfw_rule()
{
	ipfw -q delete "$RULE_NUM" >/dev/null 2>&1
	ipfw -q add "$RULE_NUM" divert "$DIVERT_PORT" tcp from any to any 80,443 out not diverted not sockarg >/dev/null 2>&1 || \
	ipfw -q add "$RULE_NUM" divert "$DIVERT_PORT" tcp from any to any 80,443 out not diverted >/dev/null 2>&1
}

start_service()
{
	load_module_if_needed ipfw
	load_module_if_needed ipdivert
	prepare_pf_ipfw_hooks
	ensure_ipfw_rule
	stop_service >/dev/null 2>&1
	"$DVTWS2" --daemon --port "$DIVERT_PORT" --lua-init=@"$ZDIR/lua/zapret-lib.lua" --lua-init=@"$ZDIR/lua/zapret-antidpi.lua" $DVTWS2_OPT
}

stop_service()
{
	pkill -x "$PROC_NAME" >/dev/null 2>&1 || true
	ipfw -q delete "$RULE_NUM" >/dev/null 2>&1
}

status_service()
{
	if pgrep -x "$PROC_NAME" >/dev/null 2>&1; then
		echo "$PROC_NAME is running"
		return 0
	fi
	echo "$PROC_NAME is not running"
	return 1
}

case "$1" in
	start)
		start_service
		;;
	stop)
		stop_service
		;;
	restart|force-reload)
		stop_service
		start_service
		;;
	status)
		status_service
		;;
	*)
		echo "Usage: $0 {start|stop|restart|force-reload|status}"
		exit 1
		;;
esac


#!/bin/sh

# this file should be placed to /usr/local/etc/rc.d and chmod 755

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin

ZDIR=/usr/local/etc/zapret2/lua
DVTWS=/usr/local/sbin/dvtws2
LOGFILE=/var/log/zapret2.log
DIVERT_PORT=990
HOSTLIST=/usr/local/etc/zapret2/ipset/zapret-hosts-user.txt
RULE_TCP=100
RULE_UDP=101

log()
{
	echo "[zapret2] $*" >> "$LOGFILE"
}

ensure_prereq()
{
	[ -x "$DVTWS" ] || {
		echo "zapret2: $DVTWS not found or not executable" >&2
		return 1
	}
	[ -f "$ZDIR/zapret-lib.lua" ] || {
		echo "zapret2: $ZDIR/zapret-lib.lua not found" >&2
		return 1
	}
	[ -f "$ZDIR/zapret-antidpi.lua" ] || {
		echo "zapret2: $ZDIR/zapret-antidpi.lua not found" >&2
		return 1
	}
	return 0
}

cleanup_rules()
{
	ipfw delete $RULE_TCP 2>/dev/null
	ipfw delete $RULE_UDP 2>/dev/null
}

stop_daemon()
{
	pkill -f "dvtws2" 2>/dev/null
}

start_service()
{
	ensure_prereq || return 1

	log "Start: $(date)"

	# prepare system
	kldload ipfw 2>/dev/null
	kldload ipdivert 2>/dev/null

	# for older pfSense versions. newer do not have these sysctls
	sysctl net.inet.ip.pfil.outbound=ipfw,pf 2>/dev/null
	sysctl net.inet.ip.pfil.inbound=ipfw,pf 2>/dev/null
	sysctl net.inet6.ip6.pfil.outbound=ipfw,pf 2>/dev/null
	sysctl net.inet6.ip6.pfil.inbound=ipfw,pf 2>/dev/null

	# required for newer pfSense versions (2.6+ tested) to return ipfw to functional state
	pfctl -d
	sleep 0.5
	pfctl -e

	cleanup_rules

	# add ipfw rules
	ipfw add $RULE_TCP divert $DIVERT_PORT tcp from any to any 80,443 out not diverted not sockarg
	ipfw add $RULE_UDP divert $DIVERT_PORT udp from any to any 443 out not diverted not sockarg

	# restart daemon
	stop_daemon
	sleep 1

	HL_ARG=""
	[ -f "$HOSTLIST" ] && HL_ARG="--hostlist=$HOSTLIST"

	"$DVTWS" \
	  --daemon \
	  --port $DIVERT_PORT \
	  --lua-init=@$ZDIR/zapret-lib.lua \
	  --lua-init=@$ZDIR/zapret-antidpi.lua \
	  \
	  --filter-tcp=80 \
	  $HL_ARG \
	  --lua-desync=fake:blob=fake_default_http:tcp_md5 \
	  --lua-desync=multisplit:pos=method+2 \
	  --new \
	  \
	  --filter-tcp=443 \
	  $HL_ARG \
	  --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 \
	  --lua-desync=multidisorder:pos=1,midsld \
	  --new \
	  \
	  --filter-udp=443 \
	  $HL_ARG \
	  --lua-desync=fake:blob=fake_default_quic:repeats=6 \
	  >> "$LOGFILE" 2>&1

	PID="$(pgrep dvtws2)"
	[ -n "$PID" ] || {
		log "start failed: dvtws2 is not running"
		echo "zapret2: failed to start dvtws2, check $LOGFILE" >&2
		return 1
	}
	log "dvtws2 PID=$PID"
	echo "zapret2 started: PID=$PID"
	return 0
}

stop_service()
{
	stop_daemon
	cleanup_rules
	log "Stop: $(date)"
	echo "zapret2 stopped"
}

status_service()
{
	PID="$(pgrep dvtws2)"
	if [ -n "$PID" ]; then
		echo "zapret2 is running: PID=$PID"
	else
		echo "zapret2 is not running"
	fi
	ipfw list | grep -E "^[0 ]*($RULE_TCP|$RULE_UDP)[[:space:]]+divert" || true
}

case "$1" in
	start|"")
		start_service
		;;
	stop)
		stop_service
		;;
	restart)
		stop_service
		sleep 1
		start_service
		;;
	status)
		status_service
		;;
	*)
		echo "usage: $0 {start|stop|restart|status}" >&2
		exit 2
		;;
esac

#!/bin/sh

# this file should be placed to /usr/local/etc/rc.d and chmod 755

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin

ZDIR=/usr/local/etc/zapret2/lua
DVTWS=/usr/local/sbin/dvtws2
LOGFILE=/var/log/zapret2.log
DIVERT_PORT=990
IPSET_DIR=/usr/local/etc/zapret2/ipset
RULE_TCP=100
RULE_UDP=101

HOSTLIST_MAIN="$IPSET_DIR/zapret-hosts.txt"
HOSTLIST_USER="$IPSET_DIR/zapret-hosts-user.txt"
HOSTLIST_AUTO="$IPSET_DIR/zapret-hosts-auto.txt"
HOSTLIST_EXCLUDE="$IPSET_DIR/zapret-hosts-user-exclude.txt"

IPLIST_MAIN4="$IPSET_DIR/zapret-ip.txt"
IPLIST_MAIN6="$IPSET_DIR/zapret-ip6.txt"
IPLIST_USER4="$IPSET_DIR/zapret-ip-user.txt"
IPLIST_USER6="$IPSET_DIR/zapret-ip-user6.txt"
IPLIST_EXCLUDE4="$IPSET_DIR/zapret-ip-exclude.txt"
IPLIST_EXCLUDE6="$IPSET_DIR/zapret-ip-exclude6.txt"

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

append_arg_for_file()
{
	# $1 - option name (for example --hostlist)
	# $2 - file path without optional .gz suffix
	local option="$1"
	local file="$2"
	local selected=

	if [ -s "$file" ]; then
		selected="$file"
	elif [ -s "$file.gz" ]; then
		selected="$file.gz"
	fi

	[ -n "$selected" ] && FILTER_ARGS="$FILTER_ARGS $option=$selected"
}

append_arg_for_plain_file()
{
	# $1 - option name
	# $2 - file path (no gzip fallback)
	local option="$1"
	local file="$2"
	[ -s "$file" ] && FILTER_ARGS="$FILTER_ARGS $option=$file"
}

collect_filter_args()
{
	FILTER_ARGS=
	local f

	append_arg_for_file --hostlist "$HOSTLIST_MAIN"
	append_arg_for_file --hostlist "$HOSTLIST_USER"
	# autohostlist must be plain text for runtime updates
	append_arg_for_plain_file --hostlist-auto "$HOSTLIST_AUTO"
	append_arg_for_file --hostlist-exclude "$HOSTLIST_EXCLUDE"

	append_arg_for_file --ipset "$IPLIST_MAIN4"
	append_arg_for_file --ipset "$IPLIST_MAIN6"
	append_arg_for_file --ipset "$IPLIST_USER4"
	append_arg_for_file --ipset "$IPLIST_USER6"
	append_arg_for_file --ipset-exclude "$IPLIST_EXCLUDE4"
	append_arg_for_file --ipset-exclude "$IPLIST_EXCLUDE6"

	# all antifilter source lists collected by ipset/get_antifilter_*.sh
	for f in "$IPSET_DIR"/antifilter-*-hosts.txt "$IPSET_DIR"/antifilter-*-hosts.txt.gz; do
		[ -e "$f" ] || continue
		case "$f" in
			*.gz) FILTER_ARGS="$FILTER_ARGS --hostlist=$f" ;;
			*) append_arg_for_file --hostlist "$f" ;;
		esac
	done
	for f in "$IPSET_DIR"/antifilter-*-ip.txt "$IPSET_DIR"/antifilter-*-ip.txt.gz "$IPSET_DIR"/antifilter-*-ip6.txt "$IPSET_DIR"/antifilter-*-ip6.txt.gz; do
		[ -e "$f" ] || continue
		case "$f" in
			*.gz) FILTER_ARGS="$FILTER_ARGS --ipset=$f" ;;
			*) append_arg_for_file --ipset "$f" ;;
		esac
	done
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

	collect_filter_args
	[ -n "$FILTER_ARGS" ] && log "filter lists:$FILTER_ARGS"

	DVTWS_CMD="\"$DVTWS\" \
	  --daemon \
	  --port $DIVERT_PORT \
	  --lua-init=@$ZDIR/zapret-lib.lua \
	  --lua-init=@$ZDIR/zapret-antidpi.lua \
	  \
	  --filter-tcp=80 \
	  --filter-l7=http \
	  $FILTER_ARGS \
	  --payload=http_req \
	  --lua-desync=fake:blob=fake_default_http:tcp_md5 \
	  --lua-desync=multisplit:pos=method+2 \
	  --new \
	  \
	  --filter-tcp=443 \
	  --filter-l7=tls \
	  $FILTER_ARGS \
	  --payload=tls_client_hello \
	  --lua-desync=fake:blob=fake_default_tls:tcp_md5:tcp_seq=-10000 \
	  --lua-desync=multidisorder:pos=1,midsld \
	  --new \
	  \
	  --filter-udp=443 \
	  --filter-l7=quic \
	  $FILTER_ARGS \
	  --payload=quic_initial \
	  --lua-desync=fake:blob=fake_default_quic:repeats=6"
	eval "$DVTWS_CMD" >> "$LOGFILE" 2>&1

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

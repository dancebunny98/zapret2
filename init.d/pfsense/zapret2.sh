#!/bin/sh

# this file should be placed to /usr/local/etc/rc.d and chmod 755

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin

PFSENSE_CONFIG=${PFSENSE_CONFIG:-/usr/local/etc/zapret2/pfsense.conf}
[ -f "$PFSENSE_CONFIG" ] && . "$PFSENSE_CONFIG"

ZDIR=${ZDIR:-/usr/local/etc/zapret2/lua}
DVTWS=${DVTWS:-/usr/local/sbin/dvtws2}
LOGFILE=${LOGFILE:-/var/log/zapret2.log}
DIVERT_PORT=${DIVERT_PORT:-990}
IPSET_DIR=${IPSET_DIR:-/usr/local/etc/zapret2/ipset}
RULE_BASE=${RULE_BASE:-100}
PORTS_TCP=${PORTS_TCP:-80,443}
PORTS_UDP=${PORTS_UDP:-443}
IFACE_WAN=${IFACE_WAN:-}
# Space-separated WAN interface list. Defaults are prefilled for this setup.
# Example: "igc3 igc4 opt4"
IFACE_WAN_LIST=${IFACE_WAN_LIST:-igc3 igc4 opt4}
# minimal : outbound + inbound TCP SYN+ACK/FIN/RST only
# combo   : minimal TCP inbound + full UDP inbound
# full    : outbound + full inbound TCP/UDP flows (high CPU load)
IPFW_INTERCEPT_MODE=${IPFW_INTERCEPT_MODE:-combo}

RULE_TCP_OUT=$RULE_BASE
RULE_UDP_OUT=$((RULE_BASE + 1))
RULE_TCP_IN_SYNACK=$((RULE_BASE + 2))
RULE_TCP_IN_FIN=$((RULE_BASE + 3))
RULE_TCP_IN_RST=$((RULE_BASE + 4))
RULE_TCP_IN_ALL=$((RULE_BASE + 5))
RULE_UDP_IN_ALL=$((RULE_BASE + 6))
LISTS_UPDATER="$IPSET_DIR/update_all_antifilter.sh"
LISTS_LOGFILE=/var/log/zapret2-lists.log
AUTO_UPDATE_LISTS=${AUTO_UPDATE_LISTS:-1}
AUTO_UPDATE_LISTS_STRICT=${AUTO_UPDATE_LISTS_STRICT:-0}
VPN_OPT4_AUTOBUILD=${VPN_OPT4_AUTOBUILD:-1}
VPN_OPT4_LIST="$IPSET_DIR/vpn-opt4.list"
VPN_OPT4_ALIAS_OUT=/usr/local/www/vpn-opt4-alias.txt
VPN_OPT4_HOSTS_OUT="$IPSET_DIR/vpn-opt4-hosts.txt"

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
	local ifaces="$IFACE_WAN_LIST"
	local base="$RULE_BASE"
	local idx=0
	local iface=
	local r

	[ -n "$IFACE_WAN" ] && ifaces="$IFACE_WAN"
	[ -n "$ifaces" ] || ifaces="__any__"

	for iface in $ifaces; do
		for r in "$base" "$((base + 1))" "$((base + 2))" "$((base + 3))" "$((base + 4))" "$((base + 5))" "$((base + 6))"; do
			ipfw delete "$r" 2>/dev/null
		done
		idx=$((idx + 1))
		base=$((RULE_BASE + idx * 10))
	done
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

_add_ipfw_rules_for_iface()
{
	# $1 - interface name, or empty for any interface
	local iface="$1"
	local out_clause="out not diverted not sockarg"
	local in_clause="in not diverted"

	if [ -n "$iface" ]; then
		out_clause="$out_clause xmit $iface"
		in_clause="$in_clause recv $iface"
	fi

	local b="$2"
	local r_tcp_out=$b
	local r_udp_out=$((b + 1))
	local r_tcp_in_synack=$((b + 2))
	local r_tcp_in_fin=$((b + 3))
	local r_tcp_in_rst=$((b + 4))
	local r_tcp_in_all=$((b + 5))
	local r_udp_in_all=$((b + 6))

	# outbound interception
	ipfw add $r_tcp_out divert $DIVERT_PORT tcp from any to any $PORTS_TCP $out_clause
	ipfw add $r_udp_out divert $DIVERT_PORT udp from any to any $PORTS_UDP $out_clause

	case "$IPFW_INTERCEPT_MODE" in
		minimal)
			# lightweight inbound interception for conntrack/autottl assistance
			ipfw add $r_tcp_in_synack divert $DIVERT_PORT tcp from any $PORTS_TCP to any tcpflags syn,ack $in_clause
			ipfw add $r_tcp_in_fin divert $DIVERT_PORT tcp from any $PORTS_TCP to any tcpflags fin $in_clause
			ipfw add $r_tcp_in_rst divert $DIVERT_PORT tcp from any $PORTS_TCP to any tcpflags rst $in_clause
			;;
		combo)
			# balanced mode: minimal tcp inbound + full udp inbound (quic replies)
			ipfw add $r_tcp_in_synack divert $DIVERT_PORT tcp from any $PORTS_TCP to any tcpflags syn,ack $in_clause
			ipfw add $r_tcp_in_fin divert $DIVERT_PORT tcp from any $PORTS_TCP to any tcpflags fin $in_clause
			ipfw add $r_tcp_in_rst divert $DIVERT_PORT tcp from any $PORTS_TCP to any tcpflags rst $in_clause
			ipfw add $r_udp_in_all divert $DIVERT_PORT udp from any $PORTS_UDP to any $in_clause
			;;
		full)
			# full inbound flow interception (very CPU intensive)
			ipfw add $r_tcp_in_all divert $DIVERT_PORT tcp from any $PORTS_TCP to any $in_clause
			ipfw add $r_udp_in_all divert $DIVERT_PORT udp from any $PORTS_UDP to any $in_clause
			;;
		*)
			log "invalid IPFW_INTERCEPT_MODE=$IPFW_INTERCEPT_MODE, fallback to minimal"
			ipfw add $r_tcp_in_synack divert $DIVERT_PORT tcp from any $PORTS_TCP to any tcpflags syn,ack $in_clause
			ipfw add $r_tcp_in_fin divert $DIVERT_PORT tcp from any $PORTS_TCP to any tcpflags fin $in_clause
			ipfw add $r_tcp_in_rst divert $DIVERT_PORT tcp from any $PORTS_TCP to any tcpflags rst $in_clause
			;;
	esac
}

add_ipfw_rules()
{
	local ifaces="$IFACE_WAN_LIST"
	local base="$RULE_BASE"
	local idx=0
	local iface=

	# backward compatibility: explicit IFACE_WAN has priority if provided
	[ -n "$IFACE_WAN" ] && ifaces="$IFACE_WAN"

	# no interface restriction -> single ruleset for any iface
	if [ -z "$ifaces" ]; then
		_add_ipfw_rules_for_iface "" "$base"
		return 0
	fi

	for iface in $ifaces; do
		_add_ipfw_rules_for_iface "$iface" "$base"
		idx=$((idx + 1))
		base=$((RULE_BASE + idx * 10))
	done
}

refresh_lists()
{
	[ "$AUTO_UPDATE_LISTS" = "1" ] || {
		log "auto list update disabled"
		return 0
	}
	[ -f "$LISTS_UPDATER" ] || {
		log "list updater script not found: $LISTS_UPDATER"
		return 0
	}

	log "running list updater: $LISTS_UPDATER"
	STRICT_MODE="$AUTO_UPDATE_LISTS_STRICT" \
	VPN_OPT4_AUTOBUILD="$VPN_OPT4_AUTOBUILD" \
	VPN_OPT4_LIST="$VPN_OPT4_LIST" \
	VPN_OPT4_ALIAS_OUT="$VPN_OPT4_ALIAS_OUT" \
	VPN_OPT4_HOSTS_OUT="$VPN_OPT4_HOSTS_OUT" \
	/bin/sh "$LISTS_UPDATER" "$LISTS_LOGFILE" >>"$LOGFILE" 2>&1 || {
		log "list updater finished with errors"
		[ "$AUTO_UPDATE_LISTS_STRICT" = "1" ] && return 1
	}
	return 0
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

	# add ipfw rules (mode-driven)
	add_ipfw_rules

	# restart daemon
	stop_daemon
	sleep 1

	refresh_lists || return 1

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
	echo "mode=$IPFW_INTERCEPT_MODE iface_wan=${IFACE_WAN:-} iface_wan_list=${IFACE_WAN_LIST:-any} divert_port=$DIVERT_PORT tcp_ports=$PORTS_TCP udp_ports=$PORTS_UDP rule_base=$RULE_BASE"
	ipfw list | grep -E "[[:space:]]divert[[:space:]]+$DIVERT_PORT[[:space:]]" || true
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
	update-lists|update_lists)
		refresh_lists
		;;
	*)
		echo "usage: $0 {start|stop|restart|status|update-lists}" >&2
		exit 2
		;;
esac

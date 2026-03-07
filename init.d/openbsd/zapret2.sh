#!/bin/sh

SCRIPT="$0"
ZAPRET_DIR="${ZAPRET_DIR:-/usr/local/etc/zapret2}"
CONF_FILE="${CONF_FILE:-$ZAPRET_DIR/init.d/openbsd/zapret2.conf}"
ARGS_FILE_DEFAULT="$ZAPRET_DIR/init.d/openbsd/dvtws2.args"

[ -f "$CONF_FILE" ] && . "$CONF_FILE"

PF_MAIN_CONF="${PF_MAIN_CONF:-/etc/pf.conf}"
PF_ANCHOR_NAME="${PF_ANCHOR_NAME:-zapret2}"
PF_ANCHOR_FILE="${PF_ANCHOR_FILE:-/etc/pf.zapret2.conf}"
PF_AUTOINSTALL_ANCHOR="${PF_AUTOINSTALL_ANCHOR:-1}"
PF_MODE="${PF_MODE:-safe}"
IFACE_WAN="${IFACE_WAN:-em0}"
PORTS_TCP="${PORTS_TCP:-80,443}"
PORTS_UDP="${PORTS_UDP:-443}"
PORT_DIVERT="${PORT_DIVERT:-989}"

DVTWS2="${DVTWS2:-$ZAPRET_DIR/nfq2/dvtws2}"
LUA_LIB="${LUA_LIB:-$ZAPRET_DIR/lua/zapret-lib.lua}"
LUA_ANTIDPI="${LUA_ANTIDPI:-$ZAPRET_DIR/lua/zapret-antidpi.lua}"
DVTWS2_ARGS_FILE="${DVTWS2_ARGS_FILE:-$ARGS_FILE_DEFAULT}"
DVTWS2_ARGS="${DVTWS2_ARGS:---lua-desync=multisplit}"

[ -f "$DVTWS2_ARGS_FILE" ] && . "$DVTWS2_ARGS_FILE"

msg()
{
	echo "[zapret2/openbsd] $*"
}

require_root()
{
	[ "$(id -u)" = "0" ] || {
		msg "run as root"
		exit 1
	}
}

require_tools()
{
	command -v pfctl >/dev/null 2>&1 || {
		msg "pfctl not found"
		exit 1
	}
	command -v pgrep >/dev/null 2>&1 || {
		msg "pgrep not found"
		exit 1
	}
}

require_files()
{
	[ -x "$DVTWS2" ] || {
		msg "missing executable: $DVTWS2"
		exit 1
	}
	[ -f "$LUA_LIB" ] || {
		msg "missing file: $LUA_LIB"
		exit 1
	}
	[ -f "$LUA_ANTIDPI" ] || {
		msg "missing file: $LUA_ANTIDPI"
		exit 1
	}
	[ -f "$PF_MAIN_CONF" ] || {
		msg "missing pf main config: $PF_MAIN_CONF"
		exit 1
	}
}

pf_anchor_lines()
{
	echo "anchor \"$PF_ANCHOR_NAME\""
	echo "load anchor \"$PF_ANCHOR_NAME\" from \"$PF_ANCHOR_FILE\""
}

pf_anchor_installed()
{
	grep -Fq "anchor \"$PF_ANCHOR_NAME\"" "$PF_MAIN_CONF" &&
	grep -Fq "load anchor \"$PF_ANCHOR_NAME\" from \"$PF_ANCHOR_FILE\"" "$PF_MAIN_CONF"
}

install_anchor()
{
	pf_anchor_installed && return 0
	msg "installing pf anchor into $PF_MAIN_CONF"
	{
		echo
		pf_anchor_lines
	} >>"$PF_MAIN_CONF"
}

write_pf_rules()
{
	case "$PF_MODE" in
		full)
			cat >"$PF_ANCHOR_FILE" <<EOF
pass out quick on $IFACE_WAN proto tcp to port { $PORTS_TCP } divert-packet port $PORT_DIVERT
pass out quick on $IFACE_WAN proto udp to port { $PORTS_UDP } divert-packet port $PORT_DIVERT
EOF
			;;
		safe|*)
			cat >"$PF_ANCHOR_FILE" <<EOF
pass in quick on $IFACE_WAN proto tcp from port { $PORTS_TCP } flags SA/SA divert-packet port $PORT_DIVERT no state
pass in quick on $IFACE_WAN proto tcp from port { $PORTS_TCP } flags R/R divert-packet port $PORT_DIVERT no state
pass in quick on $IFACE_WAN proto tcp from port { $PORTS_TCP } flags F/F divert-packet port $PORT_DIVERT no state
pass in quick on $IFACE_WAN proto tcp from port { $PORTS_TCP } no state
pass out quick on $IFACE_WAN proto tcp to port { $PORTS_TCP } divert-packet port $PORT_DIVERT no state
pass out quick on $IFACE_WAN proto udp to port { $PORTS_UDP } divert-packet port $PORT_DIVERT no state
EOF
			;;
	esac
}

clear_pf_rules()
{
	: >"$PF_ANCHOR_FILE"
}

reload_pf()
{
	pfctl -f "$PF_MAIN_CONF" >/dev/null 2>&1 || {
		msg "pfctl reload failed"
		exit 1
	}
	pfctl -e >/dev/null 2>&1 || true
}

show_pf()
{
	case "$PF_MODE" in
		full)
			cat <<EOF
pass out quick on $IFACE_WAN proto tcp to port { $PORTS_TCP } divert-packet port $PORT_DIVERT
pass out quick on $IFACE_WAN proto udp to port { $PORTS_UDP } divert-packet port $PORT_DIVERT
EOF
			;;
		safe|*)
			cat <<EOF
pass in quick on $IFACE_WAN proto tcp from port { $PORTS_TCP } flags SA/SA divert-packet port $PORT_DIVERT no state
pass in quick on $IFACE_WAN proto tcp from port { $PORTS_TCP } flags R/R divert-packet port $PORT_DIVERT no state
pass in quick on $IFACE_WAN proto tcp from port { $PORTS_TCP } flags F/F divert-packet port $PORT_DIVERT no state
pass in quick on $IFACE_WAN proto tcp from port { $PORTS_TCP } no state
pass out quick on $IFACE_WAN proto tcp to port { $PORTS_TCP } divert-packet port $PORT_DIVERT no state
pass out quick on $IFACE_WAN proto udp to port { $PORTS_UDP } divert-packet port $PORT_DIVERT no state
EOF
			;;
	esac
}

stop_daemon()
{
	pkill -f "^${DVTWS2} " >/dev/null 2>&1 || pkill -x dvtws2 >/dev/null 2>&1 || true
}

start_daemon()
{
	stop_daemon
	msg "starting dvtws2"
	eval "\"$DVTWS2\" --daemon --port \"$PORT_DIVERT\" --lua-init=@\"$LUA_LIB\" --lua-init=@\"$LUA_ANTIDPI\" $DVTWS2_ARGS"
}

do_start()
{
	require_root
	require_tools
	require_files
	[ "$PF_AUTOINSTALL_ANCHOR" = 1 ] && install_anchor
	write_pf_rules
	reload_pf
	start_daemon
}

do_stop()
{
	require_root
	require_tools
	stop_daemon
	clear_pf_rules
	reload_pf
}

do_status()
{
	if pgrep -f "^${DVTWS2} " >/dev/null 2>&1 || pgrep -x dvtws2 >/dev/null 2>&1; then
		msg "dvtws2 is running"
	else
		msg "dvtws2 is not running"
		return 1
	fi
}

do_apply_pf()
{
	require_root
	require_tools
	require_files
	[ "$PF_AUTOINSTALL_ANCHOR" = 1 ] && install_anchor
	write_pf_rules
	reload_pf
}

case "$1" in
	start)
		do_start
		;;
	stop)
		do_stop
		;;
	restart)
		do_stop
		do_start
		;;
	status)
		do_status
		;;
	show-pf|show_pf)
		show_pf
		;;
	apply-pf|apply_pf)
		do_apply_pf
		;;
	install-anchor|install_anchor)
		require_root
		require_files
		install_anchor
		;;
	*)
		echo "Usage: $SCRIPT {start|stop|restart|status|show-pf|apply-pf|install-anchor}" >&2
		exit 1
		;;
esac

exit 0

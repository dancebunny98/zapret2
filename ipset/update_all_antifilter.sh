#!/bin/sh

# Run all antifilter list scripts and optional VPN OPT4 alias builder.
# Intended for pfSense startup automation.

IPSET_DIR="$(dirname "$0")"
IPSET_DIR="$(cd "$IPSET_DIR"; pwd)"

LOGFILE="${1:-/var/log/zapret2-lists.log}"
STRICT_MODE="${STRICT_MODE:-0}"
VPN_OPT4_AUTOBUILD="${VPN_OPT4_AUTOBUILD:-1}"
VPN_OPT4_LIST="${VPN_OPT4_LIST:-$IPSET_DIR/vpn-opt4.list}"
VPN_OPT4_ALIAS_OUT="${VPN_OPT4_ALIAS_OUT:-/usr/local/www/vpn-opt4-alias.txt}"
VPN_OPT4_HOSTS_OUT="${VPN_OPT4_HOSTS_OUT:-$IPSET_DIR/vpn-opt4-hosts.txt}"

FAILED=0

log()
{
	echo "[zapret2-lists] $*" >>"$LOGFILE"
}

run_script()
{
	# $1 - script basename
	local s="$1"
	local p="$IPSET_DIR/$s"
	if [ ! -f "$p" ]; then
		log "skip missing: $s"
		return 0
	fi
	log "run: $s"
	if /bin/sh "$p" >>"$LOGFILE" 2>&1; then
		log "ok: $s"
		return 0
	fi
	log "fail: $s"
	FAILED=1
	return 1
}

run_all_lists()
{
	# base user/exclude resolver
	run_script get_user.sh || true

	# all antifilter sources available in this tree
	run_script get_antifilter_ip.sh || true
	run_script get_antifilter_ipresolve.sh || true
	run_script get_antifilter_ipsmart.sh || true
	run_script get_antifilter_ipsum.sh || true
	run_script get_antifilter_allyouneed.sh || true
}

run_vpn_opt4_builder()
{
	[ "$VPN_OPT4_AUTOBUILD" = "1" ] || {
		log "vpn opt4 builder disabled"
		return 0
	}
	[ -s "$VPN_OPT4_LIST" ] || {
		log "vpn opt4 list not found or empty: $VPN_OPT4_LIST"
		return 0
	}
	[ -f "$IPSET_DIR/build_vpn_opt4_list.sh" ] || {
		log "vpn opt4 builder script not found"
		return 0
	}
	log "run: build_vpn_opt4_list.sh"
	if /bin/sh "$IPSET_DIR/build_vpn_opt4_list.sh" "$VPN_OPT4_LIST" "$VPN_OPT4_ALIAS_OUT" "$VPN_OPT4_HOSTS_OUT" >>"$LOGFILE" 2>&1; then
		log "ok: build_vpn_opt4_list.sh"
		return 0
	fi
	log "fail: build_vpn_opt4_list.sh"
	FAILED=1
	return 1
}

log "start update cycle"
run_all_lists
run_vpn_opt4_builder
log "finish update cycle failed=$FAILED"

if [ "$FAILED" = "1" ] && [ "$STRICT_MODE" = "1" ]; then
	exit 1
fi
exit 0

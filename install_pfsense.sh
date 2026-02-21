#!/bin/sh
#
# Simple installer for pfSense (FreeBSD)
# Run on pfSense after extracting the release archive.
#

set -e

EXEDIR="$(dirname "$0")"
EXEDIR="$(cd "$EXEDIR"; pwd)"

ZAPRET_TARGET=${ZAPRET_TARGET:-/usr/local/etc/zapret2}
SBIN_TARGET=/usr/local/sbin
RC_TARGET=/usr/local/etc/rc.d
START_AFTER_INSTALL=0
CLEAN_INSTALL=1
TMP_STAGE=

usage()
{
	echo "usage: $0 [--start] [--no-clean]"
	echo "  --start    start/restart service after install"
	echo "  --no-clean do not remove previous install files before copy"
}

for arg in "$@"; do
	case "$arg" in
		--start)
			START_AFTER_INSTALL=1
			;;
		--no-clean)
			CLEAN_INSTALL=0
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "unknown option: $arg" >&2
			usage
			exit 2
			;;
	esac
done

[ "$(id -u)" = "0" ] || {
	echo "run as root" >&2
	exit 1
}

[ "$(uname -s)" = "FreeBSD" ] || {
	echo "this installer is intended for pfSense/FreeBSD" >&2
	exit 1
}

stage_source()
{
	TMP_STAGE="$(mktemp -d /tmp/zapret2-install.XXXXXX)"

	cp -R "$EXEDIR/lua" "$TMP_STAGE/"
	cp -R "$EXEDIR/ipset" "$TMP_STAGE/"
	cp -R "$EXEDIR/blockcheck2.d" "$TMP_STAGE/"
	mkdir -p "$TMP_STAGE/files"
	cp -R "$EXEDIR/files/fake" "$TMP_STAGE/files/"
	cp "$EXEDIR/blockcheck2.sh" "$TMP_STAGE/blockcheck2.sh"
	cp "$EXEDIR/install_pfsense.sh" "$TMP_STAGE/install_pfsense.sh"
	cp "$EXEDIR/config.default" "$TMP_STAGE/config.default"
	cp "$EXEDIR/pfsense.conf.example" "$TMP_STAGE/pfsense.conf.example"
	cp "$EXEDIR/init.d/pfsense/zapret2.sh" "$TMP_STAGE/zapret2.sh"
	cp "$EXEDIR/binaries/freebsd-x86_64/dvtws2" "$TMP_STAGE/dvtws2"
	cp "$EXEDIR/binaries/freebsd-x86_64/ip2net" "$TMP_STAGE/ip2net"
	cp "$EXEDIR/binaries/freebsd-x86_64/mdig" "$TMP_STAGE/mdig"
}

cleanup_previous_install()
{
	[ "$CLEAN_INSTALL" = "1" ] || return 0

	echo "* cleaning previous install files"

	rm -rf "$ZAPRET_TARGET/lua"
	rm -rf "$ZAPRET_TARGET/ipset"
	rm -rf "$ZAPRET_TARGET/blockcheck2.d"
	rm -rf "$ZAPRET_TARGET/files/fake"
	rm -f "$ZAPRET_TARGET/blockcheck2.sh"
	rm -f "$ZAPRET_TARGET/install_pfsense.sh"
rm -f "$ZAPRET_TARGET/config.default"
	rm -f "$ZAPRET_TARGET/pfsense.conf.example"

	rm -f "$SBIN_TARGET/dvtws2"
	rm -f "$SBIN_TARGET/ip2net"
	rm -f "$SBIN_TARGET/mdig"
	rm -f "$RC_TARGET/zapret2.sh"
}

fix_permissions()
{
	# normalize permissions in target tree
	find "$ZAPRET_TARGET" -type d -exec chmod 755 {} \;
	find "$ZAPRET_TARGET" -type f -exec chmod 644 {} \;
	find "$ZAPRET_TARGET" -name "*.sh" -type f -exec chmod 755 {} \;

	chmod 755 "$SBIN_TARGET/dvtws2" "$SBIN_TARGET/ip2net" "$SBIN_TARGET/mdig"
	chmod 755 "$RC_TARGET/zapret2.sh"
	chmod 755 "$ZAPRET_TARGET/blockcheck2.sh" "$ZAPRET_TARGET/install_pfsense.sh"

	chown -R root:wheel "$ZAPRET_TARGET"
	chown root:wheel "$SBIN_TARGET/dvtws2" "$SBIN_TARGET/ip2net" "$SBIN_TARGET/mdig"
	chown root:wheel "$RC_TARGET/zapret2.sh"
}

cleanup_stage()
{
	[ -n "$TMP_STAGE" ] && [ -d "$TMP_STAGE" ] && rm -rf "$TMP_STAGE"
}

trap cleanup_stage EXIT

echo "* installing zapret2 to $ZAPRET_TARGET"

stage_source

# base dirs
[ -d "$ZAPRET_TARGET" ] || mkdir -p "$ZAPRET_TARGET"
[ -d "$SBIN_TARGET" ] || mkdir -p "$SBIN_TARGET"
[ -d "$RC_TARGET" ] || mkdir -p "$RC_TARGET"

cleanup_previous_install

# copy core files
cp -R "$TMP_STAGE/lua" "$ZAPRET_TARGET/"
cp -R "$TMP_STAGE/ipset" "$ZAPRET_TARGET/"
cp -R "$TMP_STAGE/blockcheck2.d" "$ZAPRET_TARGET/"
mkdir -p "$ZAPRET_TARGET/files"
cp -R "$TMP_STAGE/files/fake" "$ZAPRET_TARGET/files/"

# ensure default hostlists
[ -f "$ZAPRET_TARGET/ipset/zapret-hosts-user.txt" ] || echo nonexistent.domain >> "$ZAPRET_TARGET/ipset/zapret-hosts-user.txt"
[ -f "$ZAPRET_TARGET/ipset/zapret-hosts-user-exclude.txt" ] || cp "$TMP_STAGE/ipset/zapret-hosts-user-exclude.txt.default" "$ZAPRET_TARGET/ipset/zapret-hosts-user-exclude.txt"
[ -f "$ZAPRET_TARGET/ipset/zapret-hosts-user-ipban.txt" ] || touch "$ZAPRET_TARGET/ipset/zapret-hosts-user-ipban.txt"

# binaries
cp "$TMP_STAGE/dvtws2" "$SBIN_TARGET/dvtws2"
cp "$TMP_STAGE/ip2net" "$SBIN_TARGET/ip2net"
cp "$TMP_STAGE/mdig" "$SBIN_TARGET/mdig"

# rc.d script
cp "$TMP_STAGE/zapret2.sh" "$RC_TARGET/zapret2.sh"

# keep key scripts in target for maintenance
cp "$TMP_STAGE/blockcheck2.sh" "$ZAPRET_TARGET/blockcheck2.sh"
cp "$TMP_STAGE/install_pfsense.sh" "$ZAPRET_TARGET/install_pfsense.sh"
cp "$TMP_STAGE/config.default" "$ZAPRET_TARGET/config.default"
cp "$TMP_STAGE/pfsense.conf.example" "$ZAPRET_TARGET/pfsense.conf.example"
[ -f "$ZAPRET_TARGET/pfsense.conf" ] || cp "$TMP_STAGE/pfsense.conf.example" "$ZAPRET_TARGET/pfsense.conf"

fix_permissions

echo "* done"
echo "  start: $RC_TARGET/zapret2.sh start"
echo "  stop : $RC_TARGET/zapret2.sh stop"
echo "  check: $RC_TARGET/zapret2.sh status"
echo "  log  : /var/log/zapret2.log"

if [ "$START_AFTER_INSTALL" = "1" ]; then
	echo "* starting service"
	"$RC_TARGET/zapret2.sh" restart
	"$RC_TARGET/zapret2.sh" status
fi

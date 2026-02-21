#!/bin/sh

# Build pfSense OPT4/WireGuard routing lists from a single input file.
# Input supports domains, IPv4/IPv6 and CIDR entries, one item per line.

set -eu

IPSET_DIR="$(dirname "$0")"
IPSET_DIR="$(cd "$IPSET_DIR"; pwd)"

IN_LIST="${1:-$IPSET_DIR/vpn-opt4.list}"
OUT_ALIAS="${2:-$IPSET_DIR/vpn-opt4-alias.txt}"
OUT_HOSTS="${3:-$IPSET_DIR/vpn-opt4-hosts.txt}"

MAX_SUBDOMAINS="${MAX_SUBDOMAINS:-300}"
USE_CRTSH="${USE_CRTSH:-1}"
MDIG_BIN="${MDIG_BIN:-/usr/local/sbin/mdig}"

TMP_BASE="${TMPDIR:-/tmp}/vpn-opt4.$$"
TMP_DOMAINS="$TMP_BASE.domains"
TMP_HOSTS="$TMP_BASE.hosts"
TMP_IP_MANUAL="$TMP_BASE.ipmanual"
TMP_IP_RESOLVED="$TMP_BASE.ipresolved"

cleanup()
{
	rm -f "$TMP_DOMAINS" "$TMP_HOSTS" "$TMP_IP_MANUAL" "$TMP_IP_RESOLVED"
}
trap cleanup EXIT INT TERM

touch "$TMP_DOMAINS" "$TMP_HOSTS" "$TMP_IP_MANUAL" "$TMP_IP_RESOLVED"

normalize_line()
{
	echo "$1" | sed -e 's/\r//g' -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

is_ipv4_or_cidr()
{
	echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'
}

is_ipv6_or_cidr()
{
	echo "$1" | grep -Eq '^[0-9a-fA-F:]+(/[0-9]{1,3})?$'
}

is_domain()
{
	echo "$1" | grep -Eq '^[a-z0-9.-]+\.[a-z0-9-]+$'
}

echo "Reading unified list: $IN_LIST"
[ -f "$IN_LIST" ] || {
	echo "Input list not found: $IN_LIST" >&2
	exit 1
}

while IFS= read -r raw || [ -n "$raw" ]; do
	line="$(normalize_line "$raw")"
	[ -n "$line" ] || continue
	value="$(echo "$line" | tr '[:upper:]' '[:lower:]')"
	value="$(echo "$value" | sed -e 's/^\*\.//' -e 's/^\.\+//' -e 's/\.+$//')"
	[ -n "$value" ] || continue

	if is_ipv4_or_cidr "$value" || is_ipv6_or_cidr "$value"; then
		echo "$value" >>"$TMP_IP_MANUAL"
	elif is_domain "$value"; then
		echo "$value" >>"$TMP_DOMAINS"
	else
		echo "Skipping unsupported entry: $line" >&2
	fi
done <"$IN_LIST"

sort -u "$TMP_DOMAINS" -o "$TMP_DOMAINS"
sort -u "$TMP_IP_MANUAL" -o "$TMP_IP_MANUAL"
cp "$TMP_DOMAINS" "$TMP_HOSTS"

if [ "$USE_CRTSH" = "1" ]; then
	echo "Expanding subdomains via crt.sh (limit per root: $MAX_SUBDOMAINS)"
	while IFS= read -r domain || [ -n "$domain" ]; do
		[ -n "$domain" ] || continue
		curl -fsSL "https://crt.sh/?q=%25.$domain&output=json" 2>/dev/null | \
			tr ',' '\n' | \
			sed -n 's/.*"name_value":"\([^"]*\)".*/\1/p' | \
			sed 's/\\n/\n/g' | \
			awk -v d="$domain" '
				{
					gsub(/\r/, "", $0)
					h=tolower($0)
					sub(/^\*\./, "", h)
					sub(/\.$/, "", h)
					if (h == "") next
					if (h !~ /^[a-z0-9.-]+$/) next
					if (h == d || h ~ ("\\." d "$")) print h
				}
			' | sort -u | head -n "$MAX_SUBDOMAINS" >>"$TMP_HOSTS" || true
	done <"$TMP_DOMAINS"
fi

sort -u "$TMP_HOSTS" -o "$TMP_HOSTS"

resolve_hosts()
{
	# $1 = family (4|6)
	if [ -x "$MDIG_BIN" ]; then
		"$MDIG_BIN" --family="$1" --threads=20 --eagain=8 --eagain-delay=300
	else
		if [ "$1" = "6" ]; then
			dig AAAA +short +time=8 +tries=2 -f -
		else
			dig A +short +time=8 +tries=2 -f -
		fi
	fi
}

if [ -s "$TMP_HOSTS" ]; then
	cat "$TMP_HOSTS" | resolve_hosts 4 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' >>"$TMP_IP_RESOLVED" || true
	cat "$TMP_HOSTS" | resolve_hosts 6 | grep -E '^[0-9a-fA-F:]+(/[0-9]+)?$' >>"$TMP_IP_RESOLVED" || true
fi

cat "$TMP_IP_MANUAL" "$TMP_IP_RESOLVED" | sort -u >"$OUT_ALIAS"
cp "$TMP_HOSTS" "$OUT_HOSTS"

echo "Done:"
echo "  Hosts list   : $OUT_HOSTS"
echo "  IP alias list: $OUT_ALIAS"

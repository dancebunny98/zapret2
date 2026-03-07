#!/bin/sh

SCRIPT="$0"
ZAPRET_DIR="${ZAPRET_DIR:-/usr/local/etc/zapret2}"
BLOCKCHECK2="${BLOCKCHECK2:-$ZAPRET_DIR/blockcheck2.sh}"
OPENBSD_INIT="${OPENBSD_INIT:-$ZAPRET_DIR/init.d/openbsd/zapret2.sh}"
BLOCKCHECK_LOG="${BLOCKCHECK_LOG:-/tmp/blockcheck2.log}"
BLOCKCHECK_SCOPE="${BLOCKCHECK_SCOPE:-common}"
BLOCKCHECK_MATCH="${BLOCKCHECK_MATCH:-}"
DVTWS2_ARGS_FILE="${DVTWS2_ARGS_FILE:-$ZAPRET_DIR/init.d/openbsd/dvtws2.args}"

msg()
{
	echo "[blockcheck/openbsd] $*"
}

die()
{
	echo "[blockcheck/openbsd] ERROR: $*" >&2
	exit 1
}

quote_sq()
{
	printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

extract_stream()
{
	case "$BLOCKCHECK_SCOPE" in
		common)
			awk '
				/^\* COMMON$/ { flag=1; next }
				/^Please note/ { flag=0 }
				flag { print }
			' "$BLOCKCHECK_LOG"
			;;
		summary|*)
			cat "$BLOCKCHECK_LOG"
			;;
	esac
}

extract_args()
{
	local line

	line="$(
		extract_stream |
		grep ': dvtws2 ' |
		{ [ -n "$BLOCKCHECK_MATCH" ] && grep -F "$BLOCKCHECK_MATCH" || cat; } |
		head -n 1
	)"

	[ -n "$line" ] || return 1
	line="${line#*: dvtws2 }"
	printf "%s\n" "$line"
}

write_args_file()
{
	local args quoted
	args="$(extract_args)" || die "no matching dvtws2 strategy found in $BLOCKCHECK_LOG"
	quoted="$(quote_sq "$args")"
	printf "DVTWS2_ARGS='%s'\n" "$quoted" >"$DVTWS2_ARGS_FILE"
	msg "installed args into $DVTWS2_ARGS_FILE"
}

run_blockcheck()
{
	[ -x "$BLOCKCHECK2" ] || die "missing blockcheck2: $BLOCKCHECK2"
	"$BLOCKCHECK2" "$@" | tee "$BLOCKCHECK_LOG"
}

case "$1" in
	run)
		shift
		run_blockcheck "$@"
		;;
	extract)
		write_args_file
		;;
	apply)
		write_args_file
		sh "$OPENBSD_INIT" restart
		;;
	auto)
		shift
		run_blockcheck "$@"
		write_args_file
		sh "$OPENBSD_INIT" restart
		;;
	*)
		echo "Usage: $SCRIPT {run|extract|apply|auto} [blockcheck2 args...]" >&2
		exit 1
		;;
esac

exit 0

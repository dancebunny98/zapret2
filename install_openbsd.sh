#!/bin/sh

set -e

SRC_DIR="$(dirname "$0")"
SRC_DIR="$(cd "$SRC_DIR"; pwd)"
DST_DIR="${ZAPRET_TARGET:-/usr/local/etc/zapret2}"
OPENBSD_INIT="${DST_DIR}/init.d/openbsd/zapret2.sh"

log()
{
	echo "[install_openbsd] $*"
}

die()
{
	echo "[install_openbsd] ERROR: $*" >&2
	exit 1
}

exists()
{
	command -v "$1" >/dev/null 2>&1
}

require_root()
{
	[ "$(id -u)" = "0" ] || die "run as root"
}

detect_system()
{
	[ "$(uname)" = "OpenBSD" ] || die "this installer supports OpenBSD only"
}

copy_project()
{
	log "installing project files to $DST_DIR"
	mkdir -p "$DST_DIR"
	(
		cd "$SRC_DIR" && tar -cf - \
			--exclude ".git" \
			--exclude ".idea" \
			--exclude ".bsp" \
			--exclude "target" \
			--exclude "project" \
			.
	) | (
		cd "$DST_DIR" && tar -xf -
	)
}

ensure_pkg()
{
	pkg_info -e "$1" >/dev/null 2>&1 || pkg_add "$1"
}

build_binaries()
{
	log "installing build dependencies"
	ensure_pkg gmake
	ensure_pkg luajit

	log "building binaries from source"
	(
		cd "$DST_DIR" &&
		gmake clean >/dev/null 2>&1 || true &&
		gmake bsd
	) || die "build failed"
}

install_binaries()
{
	log "configuring binary symlinks"
	if ! sh "$DST_DIR/install_bin.sh"; then
		build_binaries
		sh "$DST_DIR/install_bin.sh" || die "cannot configure binaries for this architecture after build"
	fi
}

start_service()
{
	log "starting openbsd zapret2"
	sh "$OPENBSD_INIT" start
}

require_root
detect_system
copy_project
install_binaries
start_service

log "done"
log "manage service with: sh $OPENBSD_INIT {start|stop|restart|status}"

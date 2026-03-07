#!/bin/sh

# one-shot installer for pfSense/FreeBSD

set -e

SRC_DIR="$(dirname "$0")"
SRC_DIR="$(cd "$SRC_DIR"; pwd)"
DST_DIR="${ZAPRET_TARGET:-/usr/local/etc/zapret2}"
RC_SCRIPT="/usr/local/etc/rc.d/zapret2"

log()
{
	echo "[install_pfsense] $*"
}

die()
{
	echo "[install_pfsense] ERROR: $*" >&2
	exit 1
}

require_root()
{
	[ "$(id -u)" = "0" ] || die "run as root"
}

exists()
{
	command -v "$1" >/dev/null 2>&1
}

first_search_result()
{
	pkg search -q "$1" 2>/dev/null | head -n 1
}

ensure_pkg_installed()
{
	local pkgname="$1"
	pkg info -e "$pkgname" >/dev/null 2>&1 || pkg install -y "$pkgname" >/dev/null 2>&1
}

find_compiler()
{
	local cc
	for cc in cc clang gcc gcc14 gcc13 gcc12 gcc11; do
		if exists "$cc"; then
			echo "$cc"
			return 0
		fi
	done
	return 1
}

find_make()
{
	local mk
	for mk in make gmake; do
		if exists "$mk"; then
			echo "$mk"
			return 0
		fi
	done
	return 1
}

install_build_deps()
{
	local luapkg compiler_pkg

	log "installing build dependencies for git clone setup"
	ensure_pkg_installed pkgconf

	if ! find_make >/dev/null 2>&1; then
		compiler_pkg="$(first_search_result '^gmake$')"
		[ -n "$compiler_pkg" ] && ensure_pkg_installed "$compiler_pkg"
	fi

	if ! find_compiler >/dev/null 2>&1; then
		compiler_pkg="$(first_search_result '^gcc[0-9]+$')"
		[ -z "$compiler_pkg" ] && compiler_pkg="$(first_search_result '^gcc$')"
		[ -n "$compiler_pkg" ] && ensure_pkg_installed "$compiler_pkg"
	fi

	if ! pkg info -e luajit >/dev/null 2>&1 && ! pkg info -e luajit-openresty >/dev/null 2>&1; then
		luapkg="$(first_search_result '^luajit-2')"
		[ -z "$luapkg" ] && luapkg="$(first_search_result '^luajit')"
		[ -z "$luapkg" ] && luapkg="$(first_search_result '^lua54$')"
		[ -z "$luapkg" ] && luapkg="$(first_search_result '^lua53$')"
		[ -z "$luapkg" ] && luapkg="$(first_search_result '^lua52$')"
		[ -z "$luapkg" ] && die "cannot find Lua/LuaJIT package in pkg repository"
		ensure_pkg_installed "$luapkg"
	fi
}

build_binaries()
{
	local mk cc

	install_build_deps
	mk="$(find_make)" || die "make/gmake not found"
	cc="$(find_compiler)" || die "C compiler not found"

	log "building binaries from source with $mk CC=$cc"
	(
		cd "$DST_DIR" &&
		"$mk" clean >/dev/null 2>&1 || true &&
		"$mk" CC="$cc" bsd
	) || die "build failed"
}

detect_system()
{
	[ "$(uname)" = "FreeBSD" ] || die "this installer supports FreeBSD/pfSense only"
	if [ -f /etc/platform ]; then
		read PLATFORM </etc/platform || PLATFORM=""
		log "detected platform: ${PLATFORM:-unknown}"
	else
		log "platform file /etc/platform is absent (continuing as generic FreeBSD)"
	fi
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

install_binaries()
{
	log "configuring binary symlinks"
	if ! sh "$DST_DIR/install_bin.sh"; then
		build_binaries
		sh "$DST_DIR/install_bin.sh" || die "cannot configure binaries for this architecture after build"
	fi
}

install_rc_script()
{
	log "installing rc script to $RC_SCRIPT"
	cp -f "$DST_DIR/init.d/pfsense/zapret2.sh" "$RC_SCRIPT"
	chmod 755 "$RC_SCRIPT"
}

start_service()
{
	log "starting zapret2"
	sh "$RC_SCRIPT" || die "failed to start zapret2"
}

require_root
detect_system
copy_project
install_binaries
install_rc_script
start_service

log "done"
log "restart manually with: sh $RC_SCRIPT"

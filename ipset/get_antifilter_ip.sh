#!/bin/sh

IPSET_DIR="$(dirname "$0")"
IPSET_DIR="$(cd "$IPSET_DIR"; pwd)"

. "$IPSET_DIR/def.sh"

getuser && {
 . "$IPSET_DIR/antifilter.helper"
 get_antifilter_source ip https://antifilter.download/list/ip.lst
}

"$IPSET_DIR/create_ipset.sh"

#!/usr/bin/env bash
#
# prefill <command…> — run <command> (the image's build step) with rlenv's pinned ccache enabled,
# filling /opt/toolchains/ccache, then write the stamp rlenv validates. See SPEC §6.2 item 18.
# Must run as `mayhem` (2000) in /mayhem; the cache dir is pre-created 2000:2000 by the base.
set -euo pipefail

CCACHE_BIN=/opt/mayhem/ccache/ccache
CACHE_DIR=/opt/toolchains/ccache
MASQ=/opt/mayhem/ccache/bin
VERSION="$("$CCACHE_BIN" --version | head -1 | sed -n 's/^ccache version //p')"
[ -n "$VERSION" ] || { echo "cannot parse ccache version" >&2; exit 1; }
[ "$#" -gt 0 ] || { echo "usage: prefill <command…>" >&2; exit 2; }

# Pinned settings: the single source of truth for both the environment and the stamp.
PINNED=(CCACHE_COMMENTS=1 CCACHE_NODIRECT=1)

for v in $(compgen -e | grep '^CCACHE_' || true); do unset "$v"; done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
: > "$work/ccache.conf"

export CCACHE_CONFIGPATH="$work/ccache.conf" CCACHE_DIR="$CACHE_DIR" CCACHE_UMASK=077 \
       CCACHE_TEMPDIR="$CACHE_DIR/tmp"
for kv in "${PINNED[@]}"; do export "${kv?}"; done
mkdir -p "$CCACHE_TEMPDIR"

# LANG/LC_*/COMPILER_PATH/GCC_* enter the cache key: deliberately left as the image ENV has them.
PATH="$MASQ:$PATH" "$@"

{ echo "version=$VERSION"; printf '%s\n' "${PINNED[@]}" | LC_ALL=C sort; } > "$CACHE_DIR/rlenv-ccache.stamp"
"$CCACHE_BIN" --show-stats 2>/dev/null | head -20 || true

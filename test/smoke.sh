#!/usr/bin/env bash
# Smoke test for the base image. Run INSIDE it:  docker run --rm -i <image> bash -s < test/smoke.sh
# Checks the contract commit images rely on: non-root user, libFuzzer + ASan/UBSan link and run,
# the standalone driver, and the ccache pre-fill helper (SPEC §6.2 item 18).
set -euo pipefail
cd "$(mktemp -d)"

echo "== user"
[ "$(id -u)" = 2000 ] || { echo "expected uid 2000, got $(id -u)" >&2; exit 1; }

echo "== libFuzzer + ASan/UBSan"
cat > h.c <<'C'
#include <stddef.h>
#include <stdint.h>
int LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) { (void)d; (void)n; return 0; }
C
$CC $SANITIZER_FLAGS $LIB_FUZZING_ENGINE h.c -o fuzz
./fuzz -runs=100

echo "== standalone driver"
$CC $SANITIZER_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o main.o
$CC $SANITIZER_FLAGS h.c main.o -o standalone
echo x > input && ./standalone input

echo "== ccache prefill"
[ -x /opt/mayhem/ccache/prefill ] || { echo "no /opt/mayhem/ccache/prefill" >&2; exit 1; }
case ":$PATH:" in *ccache*) echo "ccache must not be on the image PATH" >&2; exit 1;; esac
/opt/mayhem/ccache/prefill sh -c '$CC -c h.c -o a.o && rm a.o && $CC -c h.c -o a.o' | tee stats
grep -qE 'Hits: +1 / +2' stats || { echo "expected 1 cache hit on the second compile" >&2; exit 1; }
printf 'version=4.11.3\nCCACHE_COMMENTS=1\nCCACHE_NODIRECT=1\n' | diff - /opt/toolchains/ccache/rlenv-ccache.stamp

echo "OK"

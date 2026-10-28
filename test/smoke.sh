#!/usr/bin/env bash
# Smoke test for the base image. Run INSIDE it:  docker run --rm -i <image> bash -s < test/smoke.sh
# Checks the contract commit images rely on: non-root user, libFuzzer + ASan/UBSan link and run,
# the standalone driver, the ccache pre-fill helper (SPEC §6.2 item 18), and rlenv-build-identity.
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

echo "== rlenv-build-identity"
# The primary harness (the instrumented cmd, not the first) links a non-system .so via RUNPATH, so the
# identity covers harness + ELF interpreter + that .so. Check it against a digest computed here.
mkdir -p repo/mayhem repo/lib
echo 'int bar(void) { return 0; }' > repo/lib/bar.c
$CC -shared -fPIC repo/lib/bar.c -o repo/lib/libbar.so
printf 'int bar(void);\nint LLVMFuzzerTestOneInput(const char *d, long n) { return bar(); }\n' > b.c
$CC $LIB_FUZZING_ENGINE b.c -Lrepo/lib -lbar -Wl,-rpath,"$PWD/repo/lib" -o repo/fuzz
cat > repo/mayhem/Mayhemfile <<YAML
project: smoke
target: smoke
cmds:
  - cmd: /bin/true
  - cmd: ./fuzz @@
    cwd: $PWD/repo
    libfuzzer: true
YAML
/opt/mayhem/bin/rlenv-build-identity repo > out
interp=$(readlink -f "$(readelf -l repo/fuzz | sed -n 's/.*interpreter: \(.*\)]/\1/p')")
want=$(sha256sum repo/fuzz repo/lib/libbar.so "$interp" | cut -d' ' -f1 | LC_ALL=C sort |
  awk 'NR > 1 {printf "\n"} {printf "%s", $0}' | sha256sum | cut -d' ' -f1)
printf '%s\nsha256:%s\n' "$PWD/repo/fuzz" "$want" | diff - out
# An unresolved library: exit 1 and nothing on stdout.
rm repo/lib/libbar.so
if /opt/mayhem/bin/rlenv-build-identity repo > out 2>/dev/null; then echo "expected exit 1 on a missing .so" >&2; exit 1; fi
[ ! -s out ] || { echo "expected no stdout on a missing .so" >&2; exit 1; }

echo "OK"

# syntax=docker/dockerfile:1.7
#
# The org C/C++ base image (ghcr.io/savantenvs/base).
#
# Build once, push to a registry, and `FROM` it in every C/C++ commit-image Dockerfile
# (the SMALL form, ../mayhem-repo-integration/mayhem/Dockerfile) — it replaces `FROM debian:trixie`.
# A new fixed base is minted periodically and tagged by UTC DATE (YYYYMMDD, e.g. :20260621);
# integrations minted against that base FROM the same tag for base-layer sharing.
#
# Provides: pinned debian + apt time-travel + a STOCK clang/llvm C/C++ toolchain +
# libFuzzer/afl++ + the build tooling real OSS projects need + the non-root identities +
# the build-contract ENV. Package set is modeled on OSS-Fuzz base-image / base-builder,
# but debian (not ubuntu) and stock clang (OSS-Fuzz builds its own clang; we don't).
#
# Build & push with the helper (handles BUILD_DATE + SOURCE_DATE_EPOCH + tags):
#   ./build-and-push.sh                     # → ghcr.io/savantenvs/base:<YYYYMMDD> + :latest
#   IMAGE=ghcr.io/myorg/base ./build-and-push.sh

# --- ccache builder ----------------------------------------------------------------------
# Static ccache 4.11.3 for the OPTIONAL compile-cache pre-fill (SPEC §6.2 item 18). The version
# is part of the stamp rlenv validates, so bump it only together with rlenv. Alpine/musl gives a
# fully static binary; the final image copies just that binary.
# alpine:3.21 (manifest-list digest; re-verify with `docker buildx imagetools inspect alpine:3.21`)
FROM alpine:3.21@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507 AS ccache-builder
ARG CCACHE_VERSION=4.11.3
ARG CCACHE_SHA256=d5a340e199977b7b1e89c0add794132c977fdc2ecc7ca5451e03d43627a1b1be
RUN apk add --no-cache build-base cmake ninja perl wget tar xz linux-headers zstd-dev zstd-static file
RUN wget -q -O /tmp/ccache.tar.xz \
      "https://github.com/ccache/ccache/releases/download/v${CCACHE_VERSION}/ccache-${CCACHE_VERSION}.tar.xz" \
 && echo "${CCACHE_SHA256}  /tmp/ccache.tar.xz" | sha256sum -c - \
 && tar -C /tmp -xf /tmp/ccache.tar.xz \
 && cmake -S "/tmp/ccache-${CCACHE_VERSION}" -B /tmp/build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DSTATIC_LINK=ON -DENABLE_TESTING=OFF \
      -DREDIS_STORAGE_BACKEND=OFF -DHTTP_STORAGE_BACKEND=OFF -DENABLE_DOCUMENTATION=OFF \
      -DCMAKE_EXE_LINKER_FLAGS=-static -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
 && cmake --build /tmp/build \
 && strip /tmp/build/ccache \
 && install -D /tmp/build/ccache /out/ccache \
 && file /out/ccache | grep -q 'statically linked' \
 && /out/ccache --version | head -1 | grep -qx "ccache version ${CCACHE_VERSION}"

# Base OS pinned by digest (debian stable / trixie). Bump deliberately.
# Manifest-list digest for debian:trixie as of 2026-05-20 — VERIFY before building with:
#   docker buildx imagetools inspect debian:trixie
FROM debian:trixie@sha256:4ae67669760b807c19f23902a3fd7c121a6a70cf2ae709035674b23e712e4d62

ENV DEBIAN_FRONTEND=noninteractive

# apt sourcing — two modes, controlled solely by whether SOURCE_DATE_EPOCH is set:
#   UNSET (default): we DON'T touch apt sources → active URIs stay live (deb.debian.org,
#     latest). Build with zero config and it works; not bit-reproducible. (The official
#     debian image still records its OS snapshot date as an INERT `# snapshot...` comment
#     in debian.sources — provenance only, not used by apt.)
#   SET: repro-sources-list.sh rewrites the ACTIVE sources to snapshot.debian.org/<that
#     date>, so a build can be reproduced / replayed from a past point in time.
# Note: repro-sources-list.sh on its own ALWAYS pins (deriving a date if none given) — the
# live-when-unset behavior comes from the `if` guard below, not from the script.
# repro-sources-list.sh is left in /usr/local/bin so a commit image FROM this base can
# re-pin to ITS build date before installing project deps.
ARG SOURCE_DATE_EPOCH
ADD --chmod=755 \
    https://raw.githubusercontent.com/reproducible-containers/repro-sources-list.sh/v0.1.4/repro-sources-list.sh \
    /usr/local/bin/repro-sources-list.sh
RUN if [ -n "$SOURCE_DATE_EPOCH" ]; then \
        repro-sources-list.sh && \
        sed -i 's|snapshot\.debian\.org|snapshot-cloudflare.debian.org|g' \
            /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true ; \
    fi
RUN printf 'Acquire::http::Pipeline-Depth "10";\nAcquire::http::No-Cache "false";\n' \
      > /etc/apt/apt.conf.d/99pipeline

# C/C++ toolchain (stock clang → libFuzzer + ASan/UBSan) + the build tooling OSS projects
# commonly need. build-essential gives gcc/g++/make/libc-dev for projects that need them.
# Fuzzing engines: libFuzzer + the ASan/UBSan runtimes come from libclang-rt-19-dev
# (the `clang` meta-package does NOT include them, so `-fsanitize=fuzzer` won't link
# without it); it also ships fuzzer/FuzzedDataProvider.h. `afl++` is AFL++. The `-19-`
# is version-matched to clang 19 on the pinned trixie digest — bump both together.
# `libc6-dbg` provides glibc debug symbols (better triage/backtraces); `gdb`/`strace`/`ltrace`
# are the crash-triage + POV-analysis tools (inspect a standalone reproducer, confirm a target
# actually reads its input, walk a backtrace) — used both during integration and downstream RL tasks.
# Project-specific -dev libs are installed by the repo's mayhem/build.sh (from this same
# pinned snapshot). Everything here is pinned to the apt snapshot above.
RUN apt-get update && apt-get install -yq --no-install-recommends \
      ca-certificates git \
      build-essential \
      clang lld llvm \
      libclang-rt-19-dev \
      afl++ \
      libc6-dbg gdb strace ltrace less \
      make cmake ninja-build pkg-config \
      autoconf automake libtool m4 bison flex gettext autopoint \
      python3 python3-pip python-is-python3 \
      binutils file patch patchelf xz-utils zip unzip \
      vim \
      wget curl \
      zlib1g-dev libssl-dev \
 && rm -rf /var/lib/apt/lists/*

# Standalone (NON-fuzzer) driver: the canonical LLVM main() that feeds input files to a fuzz
# target's LLVMFuzzerTestOneInput() once each, with NO fuzzing engine. Pulled straight from
# compiler-rt, pinned to the clang-matched LLVM release (self-documenting provenance, no vendored
# copy — bump the tag with clang). mayhem/build.sh links a harness against this (instead of
# $LIB_FUZZING_ENGINE) to also produce a run-once reproducer binary — natural crash / backtrace,
# no libFuzzer runtime. Path is exported as STANDALONE_FUZZ_MAIN.
ADD https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-19.1.7/compiler-rt/lib/fuzzer/standalone/StandaloneFuzzTargetMain.c \
    /opt/mayhem/StandaloneFuzzTargetMain.c
RUN chmod 0644 /opt/mayhem/StandaloneFuzzTargetMain.c   # ADD-from-URL defaults to a non-world-readable mode

# The build contract as ENV (a commit image's mayhem/build.sh relies on these).
ENV CC=clang CXX=clang++ \
    LIB_FUZZING_ENGINE=-fsanitize=fuzzer \
    STANDALONE_FUZZ_MAIN=/opt/mayhem/StandaloneFuzzTargetMain.c \
    SANITIZER_FLAGS="-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g" \
    SRC=/mayhem


# Identities. Commit images build/fuzz as `mayhem` (2000). `agent` (1000) and `sandbox`
# (10000) are reserved for the downstream task tier; created here so task images don't
# have to. Do NOT change these UIDs. Owns /mayhem as `mayhem`; default USER mayhem.
RUN groupadd -g 10000 sandbox && useradd -u 10000 -g 10000 -M -s /usr/sbin/nologin sandbox \
 && groupadd -g 1000  agent   && useradd -u 1000  -g 1000  -m -s /bin/bash       agent \
 && groupadd -g 2000  mayhem  && useradd -u 2000  -g 2000  -m -s /bin/bash       mayhem \
 && mkdir -p /mayhem \
 && chown -R 2000:2000 /mayhem

# Optional compile-cache pre-fill (SPEC §6.2 item 18). ccache lives OFF the default PATH: a commit
# image opts in by wrapping ONLY its build step in `/opt/mayhem/ccache/prefill <cmd…>`. The helper is
# the single source of truth for the pinned settings and the stamp rlenv validates at setup.
COPY --from=ccache-builder /out/ccache /opt/mayhem/ccache/ccache
COPY --chmod=755 lib/ccache-prefill.sh /opt/mayhem/ccache/prefill
# The masquerade dir is persistent and root-owned: CMake records the resolved compiler path in
# CMakeCache.txt, so it must still exist when the grader rebuilds (SPEC §6.2 item 18). It is NOT on
# PATH; only the helper prepends it. Only compilers present here are wrapped; afl-*/hfuzz-* never.
RUN mkdir -p /opt/mayhem/ccache/bin \
 && for n in cc c++ gcc g++ clang clang++ clang-19 clang++-19 gcc-14 g++-14; do \
      if command -v "$n" >/dev/null 2>&1; then ln -s /opt/mayhem/ccache/ccache "/opt/mayhem/ccache/bin/$n"; fi; \
    done \
 && mkdir -p /opt/toolchains/ccache && chown 2000:2000 /opt/toolchains/ccache && chmod 0700 /opt/toolchains/ccache

# Provenance — record EXACTLY when this base was built. Docker's own image `.Created`
# field is (a) not a label and (b) overwritten to SOURCE_DATE_EPOCH on a time-travel
# build, so we stamp the real wall-clock time explicitly. CI MUST pass:
#   --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ARG BUILD_DATE
LABEL org.opencontainers.image.title="savantenvs/base" \
      org.opencontainers.image.description="Debian + stock Mayhem C/C++ base" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.base.name="debian:trixie" \
      mayhem.base.source_date_epoch="${SOURCE_DATE_EPOCH}"

USER mayhem
WORKDIR /mayhem

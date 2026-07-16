#!/usr/bin/env bash
#
# Build and push the mayhem C/C++ base image (./Dockerfile) to a registry.
#
# Default target is the GitHub Container Registry package ghcr.io/savantenvs/base.
# This repo lives in the forallsecure org, but a GHCR package's owner is set by the
# IMAGE namespace (ghcr.io/<owner>/...), NOT by the source repo — so we publish to the
# savantenvs org regardless. Requires a token with `write:packages` on savantenvs:
#   echo "$GHCR_TOKEN" | docker login ghcr.io -u <github-user> --password-stdin
#
# We mint a NEW fixed base periodically (not per build): the tag is the UTC DATE
# (YYYYMMDD), e.g. ghcr.io/savantenvs/base:20260621. All integrations minted against
# that base FROM the same tag, so they share base layers. Roll a new dated base
# deliberately (the date is the mint date, not a per-build timestamp).
#
# Usage:
#   ./build-and-push.sh                          # build + push IMAGE:<YYYYMMDD> and :latest
#   IMAGE=ghcr.io/myorg/base ./build-and-push.sh
#   TAG=20260621 ./build-and-push.sh              # override the immutable tag
#   PUSH=0 ./build-and-push.sh                    # build only, don't push
#   SOURCE_DATE_EPOCH=1748000000 ./build-and-push.sh   # pin apt to a specific snapshot
set -euo pipefail
cd "$(dirname "$0")"

# --- config (override via env) ----------------------------------------------
IMAGE="${IMAGE:-ghcr.io/savantenvs/base}"    # GHCR package: ghcr.io/<owner>/<name>
TAG="${TAG:-$(date -u +%Y%m%d)}"               # immutable tag = UTC DATE YYYYMMDD (e.g. 20260621)
PUSH="${PUSH:-1}"

# BUILD_DATE records the real wall-clock build time in the image label.
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# SOURCE_DATE_EPOCH is OPTIONAL and NOT set by default — a plain build uses LIVE apt.
# Set it in the environment to pin apt to that snapshot for a reproducible build.
build_args=( --build-arg "BUILD_DATE=${BUILD_DATE}" )
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  build_args+=( --build-arg "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" )
  echo ">> SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} → apt pinned to snapshot (reproducible)"
else
  echo ">> SOURCE_DATE_EPOCH unset → live apt (normal build)"
fi

echo ">> building ${IMAGE}:${TAG}  (BUILD_DATE=${BUILD_DATE})"
DOCKER_BUILDKIT=1 docker build "${build_args[@]}" \
  -t "${IMAGE}:${TAG}" \
  -t "${IMAGE}:latest" \
  .

if [ "${PUSH}" = "1" ]; then
  echo ">> pushing ${IMAGE}:${TAG} and ${IMAGE}:latest"
  docker push "${IMAGE}:${TAG}"
  docker push "${IMAGE}:latest"
  echo ">> pushed. Pin downstream builds by digest:"
  docker inspect --format '{{index .RepoDigests 0}}' "${IMAGE}:${TAG}" 2>/dev/null || true
else
  echo ">> PUSH=0 — built locally, not pushed."
fi

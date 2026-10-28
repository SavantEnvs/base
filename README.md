# ghcr.io/savantenvs/base

The C/C++ base image that every savantenvs commit image builds `FROM`: Debian, clang and libFuzzer, the
non-root users, and the helpers under `/opt/mayhem` (ccache pre-fill, `rlenv-image`). See the
`Dockerfile` header.

- **Test** (`.github/workflows/test.yml`): runs on every PR. It lints, builds both platforms, and runs
  `test/smoke.sh` inside the image.
- **Publish** (`.github/workflows/publish.yml`, run manually): mints `:<YYYYMMDD>` and `:latest`.
  Forks pin the dated tag.

The canonical image is linux/amd64, which is what CI checks. The linux/arm64 image is for local
development and testing only.

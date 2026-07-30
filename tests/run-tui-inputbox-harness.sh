#!/usr/bin/env bash
# Run the real whiptail input-box harness locally or in disposable Debian 13.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HARNESS="${REPO_DIR}/tests/tui-inputbox-harness.sh"

if command -v whiptail >/dev/null 2>&1 &&
   command -v tmux >/dev/null 2>&1 &&
   command -v ssh-keygen >/dev/null 2>&1; then
    exec "$HARNESS"
fi

command -v docker >/dev/null 2>&1 || {
    echo "whiptail/tmux are unavailable and Docker was not found" >&2
    exit 2
}

artifact_dir="${TUI_ARTIFACT_DIR:-$(mktemp -d)}"
mkdir -p "$artifact_dir"

docker run --rm \
    -e DEBIAN_FRONTEND=noninteractive \
    -e TUI_ARTIFACT_DIR=/artifacts \
    -v "${REPO_DIR}:/work:ro" \
    -v "${artifact_dir}:/artifacts" \
    -w /work \
    debian:13-slim \
    bash -lc \
    'apt-get update -qq &&
     apt-get install -y -qq openssh-client tmux whiptail >/dev/null &&
     /work/tests/tui-inputbox-harness.sh'

echo "Host screen-capture directory: $artifact_dir"

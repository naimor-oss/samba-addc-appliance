#!/usr/bin/env bash
#
# lab/run-scenario.sh - Samba-specific wrapper around the generic
# ../lab-kit/bin/run-scenario.sh runner.
#
# Responsibilities:
#   - resolve scenario short-name (e.g. "join-dc") to scenarios/<name>.sh
#   - set LAB_ENV to lab/samba.env
#   - forward flags to the lab-kit runner
#   - translate Samba-specific flags (--no-cleanup, --dry-cleanup) into
#     env vars that scenarios read in their pre_hook
#
# All the actual stage/reset/push pipeline lives in lab-kit. Scenarios own
# any WS2025-side cleanup via a pre_hook, because not every scenario needs
# the same cleanup (e.g. smoke-prepared-image skips it).
#
# Expected sibling checkout layout (per docs/REPO-SPLIT.md):
#   Debian-SAMBA/
#     lab-kit/
#     lab-router/
#     samba-addc-appliance/  <- this repo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAB_KIT_RUNNER="$REPO_DIR/../lab-kit/bin/run-scenario.sh"
ENV_FILE="$SCRIPT_DIR/samba.env"

usage() {
    cat <<USAGE
Usage: lab/run-scenario.sh <scenario> [flags]
       lab/run-scenario.sh --list

Flags forwarded to lab-kit runner:
  --no-stage      skip copying helper scripts to the host share
  --no-reset      skip samba-dc1 revert
  --no-push       skip scp of appliance scripts
  --verify-only   run verify() only (implies all --no-* above)

Samba-specific flags (consumed by scenario pre_hooks):
  --no-cleanup    set SC_SKIP_CLEANUP=1 (skip WS2025 AD cleanup)
  --dry-cleanup   set SC_DRY_CLEANUP=1 (inspect only)
  --profile NAME  source lab/profiles/NAME.env after env setup; lets
                  a scenario run with a swapped set of trap inputs
                  (hyphenated realm, edge-case NetBIOS, password with
                  special chars). Available profiles: see lab/profiles/.

Scenarios in $SCRIPT_DIR/scenarios:
USAGE
    if [[ -d "$SCRIPT_DIR/scenarios" ]]; then
        find "$SCRIPT_DIR/scenarios" -maxdepth 1 -name '*.sh' -type f 2>/dev/null \
            | sed 's|.*/||; s|\.sh$||; s|^|  |' | sort
    fi
}

if [[ ! -x "$LAB_KIT_RUNNER" ]]; then
    echo "ERROR: lab-kit runner not found at $LAB_KIT_RUNNER" >&2
    echo "Ensure lab-kit is checked out as a sibling of this repo." >&2
    exit 2
fi

SCENARIO=""
FORWARD=()
PROFILE_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --list)
            find "$SCRIPT_DIR/scenarios" -maxdepth 1 -name '*.sh' -type f 2>/dev/null \
                | sed 's|.*/||; s|\.sh$||' | sort
            exit 0 ;;
        --no-stage|--no-reset|--no-push|--verify-only)
            FORWARD+=("$1") ;;
        --no-cleanup)
            export SC_SKIP_CLEANUP=1 ;;
        --dry-cleanup)
            export SC_DRY_CLEANUP=1 ;;
        --profile)
            PROFILE_NAME="$2"; shift ;;
        -*)
            echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
        *)
            [[ -n "$SCENARIO" ]] && { echo "Only one scenario may be given." >&2; exit 2; }
            SCENARIO="$1" ;;
    esac
    shift
done

[[ -n "$SCENARIO" ]] || { usage >&2; exit 2; }

SCENARIO_FILE="$SCRIPT_DIR/scenarios/$SCENARIO.sh"
[[ -f "$SCENARIO_FILE" ]] || { echo "No such scenario: $SCENARIO_FILE" >&2; exit 2; }

# Source the named profile if --profile was given. Profiles use
# `export SC_X=...` so all overrides reach the lab-kit runner and
# the scenario.
if [[ -n "$PROFILE_NAME" ]]; then
    PROFILE_FILE="$SCRIPT_DIR/profiles/$PROFILE_NAME.env"
    if [[ ! -f "$PROFILE_FILE" ]]; then
        echo "ERROR: no such profile: $PROFILE_FILE" >&2
        echo "Available profiles:" >&2
        find "$SCRIPT_DIR/profiles" -maxdepth 1 -name '*.env' -type f 2>/dev/null \
            | sed 's|.*/||; s|\.env$||; s|^|  |' | sort >&2
        exit 2
    fi
    # shellcheck disable=SC1090
    source "$PROFILE_FILE"
fi

# cd to repo root so LAB_STAGE_SOURCES and LAB_PUSH_FILES globs in samba.env
# resolve against the expected layout.
cd "$REPO_DIR"

LAB_ENV="$ENV_FILE" exec "$LAB_KIT_RUNNER" "$SCENARIO_FILE" "${FORWARD[@]+"${FORWARD[@]}"}"

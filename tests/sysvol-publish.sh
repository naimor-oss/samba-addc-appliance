#!/usr/bin/env bash
# Atomic per-GPO SYSVOL publication (code-review session plan 03). Exercises
# the gpo-publish block of the generated sysvol-sync against real
# directories: a concurrent reader never sees a mixed generation, faults
# leave one complete live tree, and the replaced tree can be rolled back.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE="${SCRIPT_DIR}/../prepare-image.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sysvol-publish-test.XXXXXX")
trap 'kill "${reader_pid:-0}" 2>/dev/null; rm -rf "$T"' EXIT
command -v python3 >/dev/null || { echo "SKIP: python3 missing"; exit 0; }

PASS=0
FAIL=0
check() {
    if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); printf 'FAIL  %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

# The block under test, as generated into /usr/local/sbin/sysvol-sync.
block=$(awk '/^# --- BEGIN gpo-publish/{f=1} f{print} /^# --- END gpo-publish/{f=0}' "$PREPARE")
[[ -n "$block" ]] || { echo "FAIL: gpo-publish block not found" >&2; exit 1; }
say() { printf '%s\n' "$*" >> "$T/log"; }
read_local_gpt_version() {
    awk -F= 'tolower($1) ~ /^version$/ { gsub(/[\r ]/, "", $2); print $2; f=1; exit } END { if (!f) print 0 }' \
        "$1/GPT.INI" 2>/dev/null || echo 0
}
SYSVOL_STAGE_ROOT="$T/stage"
eval "$block"

P="$T/sysvol/lab.example/Policies"
G='{31B2F340-016D-11D2-945F-00C04FB984F9}'
gen() {   # DIR VERSION [FILES]
    rm -rf "$1"; mkdir -p "$1/Machine"
    printf '[General]\r\nVersion=%s\r\n' "$2" > "$1/GPT.INI"
    printf 'generation %s\n' "$2" > "$1/Machine/Registry.pol"
    local i
    for ((i = 0; i < ${3:-0}; i++)); do printf '%s\n' "$2" > "$1/Machine/f$i"; done
}
live_version() { read_local_gpt_version "$P/$G"; }

gpo_stage_ready "$P" || { echo "FAIL: staging area not ready" >&2; exit 1; }

echo "== new GPO =="
gen "$SYSVOL_STAGE_ROOT/incoming/$G" 1
gpo_validate "$SYSVOL_STAGE_ROOT/incoming/$G" "$G" 1 && gpo_publish "$P" "$G" "$SYSVOL_STAGE_ROOT/incoming/$G"
check "new GPO is published" 1 "$(live_version)"

echo "== concurrent reader sees only whole generations =="
# The reader opens the GPO directory first (as an SMB client's handle does),
# then reads GPT.INI and a policy file inside it.
: > "$T/mixed"
(
    while :; do
        out=$(cd "$P/$G" 2>/dev/null && v=$(awk -F= '/^Version/ {gsub(/\r/,"",$2); print $2}' GPT.INI) \
              && c=$(cat Machine/Registry.pol) && printf '%s|%s' "$v" "$c") || continue
        [[ "$out" == "${out%%|*}|generation ${out%%|*}" ]] || echo "$out" >> "$T/mixed"
    done
) &
reader_pid=$!
for v in $(seq 2 120); do
    gen "$SYSVOL_STAGE_ROOT/incoming/$G" "$v" 20
    gpo_publish "$P" "$G" "$SYSVOL_STAGE_ROOT/incoming/$G" || echo "publish $v failed" >> "$T/mixed"
done
kill "$reader_pid" 2>/dev/null; wait "$reader_pid" 2>/dev/null
check "no mixed generation observed across 119 publications" "" "$(head -3 "$T/mixed")"
check "last generation is live" 120 "$(live_version)"
check "replaced generation is retained" 119 "$(read_local_gpt_version "$SYSVOL_STAGE_ROOT/previous/$G")"

echo "== more than 100 deletions =="
gen "$SYSVOL_STAGE_ROOT/incoming/$G" 121 150
gpo_publish "$P" "$G" "$SYSVOL_STAGE_ROOT/incoming/$G"
gen "$SYSVOL_STAGE_ROOT/incoming/$G" 122 2
gpo_publish "$P" "$G" "$SYSVOL_STAGE_ROOT/incoming/$G"
check "150 -> 2 files leaves exactly the new tree" 4 "$(find "$P/$G" -type f | wc -l)"

echo "== faults leave one complete live generation =="
for fault in before-exchange exchange; do
    gen "$SYSVOL_STAGE_ROOT/incoming/$G" 200
    rc=0; SYSVOL_SYNC_FAULT=$fault gpo_publish "$P" "$G" "$SYSVOL_STAGE_ROOT/incoming/$G" || rc=$?
    check "fault at $fault fails the publication" 1 "$rc"
    check "fault at $fault keeps the old generation live" 122 "$(live_version)"
    check "fault at $fault keeps the live tree complete" 4 "$(find "$P/$G" -type f | wc -l)"
    rm -rf "${SYSVOL_STAGE_ROOT:?}/incoming/$G"
done
gen "$SYSVOL_STAGE_ROOT/incoming/$G" 201
SYSVOL_SYNC_FAULT=after-exchange gpo_publish "$P" "$G" "$SYSVOL_STAGE_ROOT/incoming/$G"
check "fault after exchange still leaves the new generation live" 201 "$(live_version)"

echo "== validation refuses bad staged trees =="
gen "$T/bad" 300; ln -s /etc/passwd "$T/bad/Machine/evil"
gpo_validate "$T/bad" "$G" 300 && r=accepted || r=refused
check "a symlink in the staged tree is refused" refused "$r"
gen "$T/bad" 5
gpo_validate "$T/bad" "$G" 300 && r=accepted || r=refused
check "a staged version below the target is refused" refused "$r"
gen "$T/bad" 300
gpo_validate "$T/bad" '{not-a-guid}' 300 && r=accepted || r=refused
check "a non-GUID name is refused" refused "$r"
rm -f "$T/bad/GPT.INI"
gpo_validate "$T/bad" "$G" 1 && r=accepted || r=refused
check "a tree without GPT.INI is refused" refused "$r"

echo "== rollback =="
gpo_rollback "$P" "$G"
check "rollback restores the previous generation" 122 "$(live_version)"
check "rollback keeps the rolled-back generation" 201 "$(read_local_gpt_version "$SYSVOL_STAGE_ROOT/previous/$G")"

echo "== orphan detach =="
gpo_detach "$P" "$G"
check "orphan is no longer live" no "$([[ -e "$P/$G" ]] && echo yes || echo no)"
check "detached orphan is retained" 122 "$(read_local_gpt_version "$SYSVOL_STAGE_ROOT/previous/$G")"
gpo_rollback "$P" "$G"
check "a detached orphan can be rolled back" 122 "$(live_version)"

echo "== interrupted runs and retention =="
mkdir -p "$SYSVOL_STAGE_ROOT/incoming/run.crashed/$G"
mkdir -p "$SYSVOL_STAGE_ROOT/previous/{OLD}" && touch -d '40 days ago' "$SYSVOL_STAGE_ROOT/previous/{OLD}"
gpo_stage_ready "$P"
check "leftovers of an interrupted run are removed" no \
    "$([[ -e "$SYSVOL_STAGE_ROOT/incoming/run.crashed" ]] && echo yes || echo no)"
check "retained generations older than 30 days are pruned" no \
    "$([[ -e "$SYSVOL_STAGE_ROOT/previous/{OLD}" ]] && echo yes || echo no)"
check "live tree untouched by cleanup" 122 "$(live_version)"

echo "== staging on another filesystem is refused =="
if [[ -d /dev/shm && "$(stat -c %d /dev/shm)" != "$(stat -c %d "$T")" ]]; then
    other=$(mktemp -d /dev/shm/sysvol-stage.XXXXXX)
    SYSVOL_STAGE_ROOT="$other" gpo_stage_ready "$P" && r=accepted || r=refused
    rm -rf "$other"
    check "cross-filesystem staging is refused" refused "$r"
else
    echo "  (skipped: no second filesystem)"
fi

echo
echo "summary: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

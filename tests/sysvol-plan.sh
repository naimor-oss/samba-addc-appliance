#!/usr/bin/env bash
# What a sysvol-sync cycle decides to do before any network call (the
# gpo-plan block of the generated sysvol-sync): which GPOs are behind, which
# local folders are orphans, and that a cycle with nothing to do has an empty
# plan. A never-edited GPO (AD version 0) whose folder is missing must count
# as behind: "0 >= 0" used to read as current, so such a GPO was never pulled.
# shellcheck disable=SC2016  # the greps match the generated script's literal '$' text
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE="${SCRIPT_DIR}/../prepare-image.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sysvol-plan-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
check() {
    if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); printf 'FAIL  %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}

# The blocks under test, as generated into /usr/local/sbin/sysvol-sync. The
# publish block supplies local_gpt_present; the plan block uses it.
blocks=$(awk '/^# --- BEGIN gpo-(publish|plan)/{f=1} f{print} /^# --- END gpo-(publish|plan)/{f=0}' "$PREPARE")
[[ "$blocks" == *"BEGIN gpo-plan"* ]] || { echo "FAIL: gpo-plan block not found" >&2; exit 1; }
say() { :; }
read_local_gpt_version() {
    local f
    for f in "$1/GPT.INI" "$1/gpt.ini" "$1/Gpt.ini"; do
        [[ -f "$f" ]] || continue
        awk -F= 'tolower($1) ~ /^version$/ { gsub(/[\r ]/, "", $2); print $2; exit }' "$f"
        return
    done
    echo 0
}
eval "$blocks"

P="$T/sysvol/lab.example/Policies"
mkdir -p "$P"
gpt() {   # GUID VERSION [FILENAME]
    mkdir -p "$P/$1"
    printf '[General]\r\nVersion=%s\r\n' "$2" > "$P/$1/${3:-GPT.INI}"
}
sorted() { printf '%s\n' "$@" | sort | tr '\n' ' ' | sed 's/ $//'; }

A='{AAAAAAAA-0000-0000-0000-000000000001}'   # current
B='{BBBBBBBB-0000-0000-0000-000000000002}'   # stale
C='{CCCCCCCC-0000-0000-0000-000000000003}'   # version 0, folder present
D='{DDDDDDDD-0000-0000-0000-000000000004}'   # version 0, folder missing
E='{EEEEEEEE-0000-0000-0000-000000000005}'   # newer locally than AD
F='{FFFFFFFF-0000-0000-0000-000000000006}'   # lower-case gpt.ini, current
G='{99999999-0000-0000-0000-000000000007}'   # unreadable Version
O='{0000000F-0000-0000-0000-00000000000F}'   # orphan: no AD object

# shellcheck disable=SC2034  # read by the eval'd gpo-plan block
declare -A target_versions=(
    ["$A"]=5 ["$B"]=9 ["$C"]=0 ["$D"]=0 ["$E"]=3 ["$F"]=2 ["$G"]=1
)
gpt "$A" 5
gpt "$B" 7
gpt "$C" 0
gpt "$E" 4
gpt "$F" 2 gpt.ini
gpt "$G" x
gpt "$O" 1
mkdir -p "$P/PolicyDefinitions"

echo "== plan =="
gpo_plan "$P"
check "behind: stale, missing at version 0, unreadable" "$(sorted "$B" "$D" "$G")" "$(sorted "${PLAN_BEHIND[@]}")"
check "orphans: GUID folders without an AD object only" "$O" "$(sorted "${PLAN_ORPHANS[@]}")"

echo "== nothing to do =="
gpt "$B" 9
gpt "$D" 0
gpt "$G" 1
rm -rf "${P:?}/$O"
gpo_plan "$P"
check "nothing behind once every folder is current" 0 "${#PLAN_BEHIND[@]}"
check "no orphans once the orphan is gone" 0 "${#PLAN_ORPHANS[@]}"

echo "== the fast path in the generated script =="
# The plan must run, and an empty plan must exit, before peer discovery: an
# idle cycle makes no network call and writes no log line.
gen=$(awk '/^cat > \/usr\/local\/sbin\/sysvol-sync << .SYNCEOF./{f=1;next} /^SYNCEOF$/{f=0} f' "$PREPARE")
plan_at=$(grep -n '^gpo_plan "\$POLICIES_DIR"' <<<"$gen" | cut -d: -f1)
peers_at=$(grep -n '^# --- discover candidate peers' <<<"$gen" | cut -d: -f1)
start_at=$(grep -n '^say "start: .*behind=' <<<"$gen" | cut -d: -f1)
check "the plan runs before peer discovery" yes "$([[ -n "$plan_at" && -n "$peers_at" && "$plan_at" -lt "$peers_at" ]] && echo yes || echo no)"
check "a sync cycle logs its start only after the fast path" yes "$([[ -n "$start_at" && "$start_at" -gt "$plan_at" ]] && echo yes || echo no)"

echo "== per-GPO NTACL =="
# The ACL step itself needs a Samba DC (the lab scenario covers it). Here:
# the embedded Python compiles, every publication is followed by it, and the
# whole-tree reset runs only when it failed for some GPO.
py=$(awk '/<<.PYACL.$/{f=1;next} /^PYACL$/{f=0} f' <<<"$gen")
check "the per-GPO NTACL code is embedded" yes "$([[ -n "$py" ]] && echo yes || echo no)"
if command -v python3 >/dev/null; then
    printf '%s\n' "$py" > "$T/pyacl.py"
    python3 -m py_compile "$T/pyacl.py" 2>/dev/null && r=compiles || r=broken
    check "the per-GPO NTACL code compiles" compiles "$r"
fi
publish_at=$(grep -n 'if gpo_publish "\$POLICIES_DIR"' <<<"$gen" | cut -d: -f1)
acl_at=$(grep -n 'if gpo_set_acl "\$guid"' <<<"$gen" | cut -d: -f1)
check "each publication sets that GPO's NTACL" yes \
    "$([[ -n "$publish_at" && -n "$acl_at" && "$acl_at" -gt "$publish_at" && "$acl_at" -lt $((publish_at + 4)) ]] && echo yes || echo no)"
check "the whole-tree reset is only a fallback" 1 \
    "$(grep -c '^if \[\[ \$acl_failed -eq 1 \]\]; then' <<<"$gen")"

echo
echo "summary: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

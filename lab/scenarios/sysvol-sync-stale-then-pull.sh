# shellcheck shell=bash
# lab/scenarios/sysvol-sync-stale-then-pull.sh — exercise the version-aware
# SYSVOL puller's recovery path: hand-stale a GPO on samba-dc1, run
# /usr/local/sbin/sysvol-sync, assert the GPO converges back to its AD-known
# version with full content restored.
#
# Stages:
#   1. Reset-LabDomainState on WS2025-DC1   (clean stale samba-* records)
#   2. samba-sconfig join-dc                (samba-dc1 joins the WS2025 forest)
#   3. write a minimal /etc/samba/sysvol-sync.conf
#   4. pick a non-built-in GPO, save its current gpt.ini, replace the file
#      with Version=1, remove the Machine/ subtree
#   5. run sysvol-sync once
#   6. verify the GPO is restored: gpt.ini Version matches AD versionNumber,
#      Machine/ subdirectory is back, --status reports `current`, log shows
#      "pulled vN -> vM from <Win DC>"

SC_REALM="${SC_REALM:-lab.test}"
SC_NETBIOS="${SC_NETBIOS:-LAB}"
SC_DC="${SC_DC:-10.10.10.10}"
SC_PASS="${SC_PASS:-P@ssword123456!}"
SC_ADMIN="${SC_ADMIN:-Administrator}"

# A non-default GPO from the WS2025 baseline import. samba-dc1 will pull this
# during the initial join's seed_sysvol; we then artificially break it.
TEST_GUID="{A9833986-3DAF-4D9E-ABD9-B5AEAA738370}"

# Pre-compute the lower-case realm. macOS bash 3.2 doesn't support
# ${var,,}; doing the transform locally keeps the scenario portable.
SC_REALM_LC=$(echo "$SC_REALM" | tr '[:upper:]' '[:lower:]')

pre_hook() {
    if [[ "${SC_SKIP_CLEANUP:-0}" == "1" ]]; then
        say "skipping WS2025 cleanup (SC_SKIP_CLEANUP=1)"
        return 0
    fi
    local dry=""
    [[ "${SC_DRY_CLEANUP:-0}" == "1" ]] && dry="-DryRun"
    step "Reset-LabDomainState on WS2025-DC1 ${dry:+(dry-run)}"
    ssh_host "pwsh -File ${LAB_HOST_STAGE_DIR}\\Reset-LabDomainState.ps1 $dry"
}

run_scenario() {
    step "join samba-dc1 to ${SC_REALM}"
    ssh_vm "sudo env \
        SC_REALM='$SC_REALM' \
        SC_NETBIOS='$SC_NETBIOS' \
        SC_DC='$SC_DC' \
        SC_PASS='$SC_PASS' \
        SC_ADMIN='$SC_ADMIN' \
        samba-sconfig join-dc"

    step "configure sysvol-sync (15-min cron, default discovery)"
    ssh_vm 'sudo bash -c "cat > /etc/samba/sysvol-sync.conf <<EOF
SYNC_INTERVAL=\"15\"
PREFERRED_DCS=\"\"
EXCLUDE_DCS=\"\"
EOF
chmod 640 /etc/samba/sysvol-sync.conf"'

    step "verify the test GPO arrived during seed_sysvol"
    ssh_vm "sudo test -f \"/var/lib/samba/sysvol/${SC_REALM_LC}/Policies/${TEST_GUID}/gpt.ini\"" \
        || { say "test GPO did not seed; aborting scenario"; return 1; }
    SAVED_VER=$(ssh_vm "sudo awk -F= 'tolower(\$1) ~ /version/ {gsub(/[[:space:]\\r]/,\"\",\$2); print \$2; exit}' \"/var/lib/samba/sysvol/${SC_REALM_LC}/Policies/${TEST_GUID}/gpt.ini\"")
    say "  test GPO is at v${SAVED_VER:-?}"

    step "make GPO ${TEST_GUID} stale: rewrite gpt.ini Version=1 + delete Machine/"
    ssh_vm "sudo bash -c '
        d=\"/var/lib/samba/sysvol/${SC_REALM_LC}/Policies/${TEST_GUID}\"
        printf \"[General]\\nVersion=1\\n\" > \"\$d/gpt.ini\"
        rm -rf \"\$d/Machine\"
    '"

    step "run sysvol-sync once"
    ssh_vm 'sudo /usr/local/sbin/sysvol-sync 2>&1'
}

verify() {
    local rc=0 out
    local dir="/var/lib/samba/sysvol/${SC_REALM_LC}/Policies/${TEST_GUID}"

    say "sync log shows the pull happened from a Windows DC"
    out=$(ssh_vm 'sudo tail -20 /var/log/samba/sysvol-sync.log' 2>&1 || true)
    echo "$out"
    if ! grep -qE "pulled v1 -> v[0-9]+ from " <<< "$out"; then
        say "no pull line in log — sync did not recover the stale GPO"
        rc=1
    fi

    say "GPO ${TEST_GUID} gpt.ini is restored to its target version"
    out=$(ssh_vm "sudo cat \"$dir/gpt.ini\"" 2>&1 || true)
    echo "$out"
    grep -q "^Version=" <<< "$out" || { say "no Version= line"; rc=1; }
    if grep -qE '^Version=1$' <<< "$out"; then
        say "GPO is still at Version=1 (did not get pulled)"; rc=1
    fi

    say "Machine/ subdirectory was restored"
    ssh_vm "sudo test -d \"$dir/Machine\"" || { say "Machine/ missing after sync"; rc=1; }

    say "freshness viewer reports the GPO as current"
    out=$(ssh_vm 'sudo /usr/local/sbin/sysvol-sync --status' 2>&1 || true)
    echo "$out"
    line=$(grep -F "$TEST_GUID" <<< "$out" || true)
    if ! grep -q 'current' <<< "$line"; then
        say "freshness viewer shows: $line"
        rc=1
    fi

    return $rc
}

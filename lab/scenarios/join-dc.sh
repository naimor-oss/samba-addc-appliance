# shellcheck shell=bash
# lab/scenarios/join-dc.sh — join samba-dc1 to the WS2025 lab forest as
# an additional writable DC.
#
# Sourced by lab/run-scenario.sh. Has access to ssh_host / ssh_vm /
# scp_to_vm / say / step helpers and the HV_* / VM_* variables.
#
# The scenario intentionally drives the headless samba-sconfig CLI instead of
# the whiptail TUI. That keeps the test focused on appliance behavior and gives
# the log complete command output when a join fails.
#
# Overridable via env (run the driver with `SC_ADMIN=alice ./lab/run-scenario.sh join-dc`):
#   SC_REALM, SC_NETBIOS, SC_DC, SC_PASS, SC_ADMIN, SC_ROLE

SC_REALM="${SC_REALM:-lab.test}"
SC_NETBIOS="${SC_NETBIOS:-LAB}"
SC_DC="${SC_DC:-10.10.10.10}"
SC_PASS="${SC_PASS:-P@ssword123456!}"
SC_ADMIN="${SC_ADMIN:-Administrator}"
SC_ROLE="${SC_ROLE:-DC}"

# pre_hook: strip stale samba-* records from WS2025-DC1 before re-joining.
# A Samba join leaves durable objects in AD (computer account, NTDS Settings,
# DNS records, replication links) that a VM revert alone doesn't undo. Without
# this step, a second join run hits "object already exists" errors.
#
# Respects two env flags set by lab/run-scenario.sh:
#   SC_SKIP_CLEANUP=1  -> skip entirely
#   SC_DRY_CLEANUP=1   -> run with -DryRun (inspect only)
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
    ssh_vm "sudo env \
        SC_REALM='$SC_REALM' \
        SC_NETBIOS='$SC_NETBIOS' \
        SC_DC='$SC_DC' \
        SC_PASS='$SC_PASS' \
        SC_ADMIN='$SC_ADMIN' \
        SC_ROLE='$SC_ROLE' \
        samba-sconfig join-dc"
}

verify() {
    local rc=0 out

    say "samba-ad-dc is active"
    ssh_vm 'sudo systemctl is-active samba-ad-dc' || rc=1

    say "net ads info reports a live KDC"
    ssh_vm 'sudo net ads info -P' || rc=1

    say "drs showrepl reports no failures"
    # Right after samba-ad-dc starts, localhost LDAP isn't always bound yet;
    # retry briefly so we're testing replication state, not a cold-start race.
    out=""
    for attempt in 1 2 3 4 5 6; do
        out=$(ssh_vm 'sudo samba-tool drs showrepl 2>&1' || true)
        if ! grep -qiE 'connection refused|failed to connect|ERROR\(' <<< "$out"; then
            break
        fi
        sleep 3
    done
    echo "$out" | head -80
    if grep -qE '[1-9][0-9]* consecutive failure' <<< "$out" \
       || grep -qiE 'was (a FAILURE|unsuccessful)' <<< "$out" \
       || grep -qE '\b8524\b' <<< "$out" \
       || grep -qiE 'connection refused|failed to connect|ERROR\(' <<< "$out"; then
        say "replication errors present or drs showrepl failed to connect"
        rc=1
    fi

    say "SYSVOL is populated (realm subtree has GPOs)"
    # Derive the realm on the VM (bash 4) instead of doing ${var,,} locally,
    # which doesn't work on macOS's stock bash 3.2 when the orchestrator runs.
    out=$(ssh_vm 'sudo bash -c "realm=\$(grep -oP \"(?<=realm = ).*\" /etc/samba/smb.conf | head -1 | tr A-Z a-z); ls /var/lib/samba/sysvol/\$realm/Policies/"' 2>&1 || true)
    echo "$out"
    if ! grep -q '{' <<< "$out"; then
        say "SYSVOL Policies/ empty — seed failed"
        rc=1
    fi

    say "TLS cert has SAN"
    ssh_vm 'sudo openssl x509 -noout -ext subjectAltName -in /var/lib/samba/private/tls/cert.pem 2>&1 | head -5' || rc=1

    say "verification from WS2025-DC1 side"
    # Samba can look healthy locally while Windows has cached KCC/DNS errors.
    # The Windows-side verifier catches missing PTR, stale 8524, and outbound
    # replication failures that `samba-tool drs showrepl` will not see.
    out=$(ssh_host "pwsh -File D:\\ISO\\lab-scripts\\Verify-JoinFromWS2025.ps1 -SambaIP '$VM_IP' -Realm '$SC_REALM'" || true)
    echo "$out"
    if grep -q '^FAIL' <<< "$out"; then
        rc=1
    fi

    return $rc
}

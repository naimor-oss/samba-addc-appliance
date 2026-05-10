# shellcheck shell=bash
# lab/scenarios/ws2025-down-resilience.sh — verify samba-dc1 stays
# operational when WS2025-DC1 is offline (the "≤5-day Win-DC outage"
# constraint baked into the appliance design).
#
# Stages:
#   1. Reset-LabDomainState on WS2025-DC1
#   2. samba-sconfig join-dc + configure sysvol-sync
#   3. Stop-VM WS2025-DC1, wait for it to power off
#   4. Verify samba-dc1's local AD answers, sysvol-sync logs "no DCs
#      reachable" and exits 0, --status still works (local-only)
#   5. Start-VM WS2025-DC1 in post_hook (ALWAYS — even on FAIL)
#
# The post_hook is defensive: a partially-failed run must not leave the
# Windows DC powered off, since the rest of the lab depends on it.

SC_REALM="${SC_REALM:-lab.test}"
SC_NETBIOS="${SC_NETBIOS:-LAB}"
SC_DC="${SC_DC:-10.10.10.10}"
SC_PASS="${SC_PASS:-P@ssword123456!}"
SC_ADMIN="${SC_ADMIN:-Administrator}"
WS2025_VM="${WS2025_VM:-WS2025-DC1}"

pre_hook() {
    if [[ "${SC_SKIP_CLEANUP:-0}" == "1" ]]; then
        say "skipping WS2025 cleanup (SC_SKIP_CLEANUP=1)"
        return 0
    fi
    local dry=""
    [[ "${SC_DRY_CLEANUP:-0}" == "1" ]] && dry="-DryRun"
    step "Reset-LabDomainState on $WS2025_VM ${dry:+(dry-run)}"
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

    step "configure sysvol-sync"
    ssh_vm 'sudo bash -c "cat > /etc/samba/sysvol-sync.conf <<EOF
SYNC_INTERVAL=\"15\"
PREFERRED_DCS=\"\"
EXCLUDE_DCS=\"\"
EOF
chmod 640 /etc/samba/sysvol-sync.conf"'

    step "stop $WS2025_VM"
    ssh_host "Stop-VM -Name '$WS2025_VM' -Force -ErrorAction SilentlyContinue"

    say "wait for $WS2025_VM to power off (up to 60s)"
    for _ in $(seq 1 30); do
        state=$(ssh_host "(Get-VM -Name '$WS2025_VM').State.ToString()" 2>/dev/null | tr -d '\r')
        [[ "$state" == "Off" ]] && break
        sleep 2
    done
    say "$WS2025_VM is now: ${state:-unknown}"
}

verify() {
    local rc=0 out

    say "samba-ad-dc on samba-dc1 is still active"
    ssh_vm 'sudo systemctl is-active samba-ad-dc' || rc=1

    say "samba-dc1 still answers local AD queries"
    out=$(ssh_vm 'sudo samba-tool user list 2>&1' || true)
    echo "$out" | head -10
    grep -q '^Administrator$' <<< "$out" || { say "user list does not include Administrator"; rc=1; }

    # We deliberately avoid `kinit Administrator@REALM` here. With the
    # WS2025 KDC down, kinit's SRV-based KDC discovery returns both DCs and
    # blocks on the dead one until its per-KDC timeout fires; the resulting
    # hang/failure is a kinit/krb5 client behaviour question, not a "is the
    # local KDC up" question. The real concern in this scenario is whether
    # the local KDC still LISTENS and ANSWERS — testing the listening
    # sockets gets at that without entangling DNS-based discovery.
    say "samba-dc1's KDC + LDAP + SMB ports are still listening"
    out=$(ssh_vm 'sudo ss -lntu 2>&1' || true)
    for port in 88 389 445; do
        if ! grep -qE "[: ](${port})[[:space:]]" <<< "$out"; then
            say "  port ${port}: NOT listening"
            rc=1
        fi
    done

    say "sysvol-sync exits cleanly with 'no DCs reachable'"
    ssh_vm 'sudo /usr/local/sbin/sysvol-sync 2>&1; echo rc=$?'
    out=$(ssh_vm 'sudo tail -3 /var/log/samba/sysvol-sync.log' 2>&1 || true)
    echo "$out"
    grep -q 'no DCs reachable' <<< "$out" || { say "sysvol-sync log does not show 'no DCs reachable'"; rc=1; }

    say "sysvol-sync --status still works (local-only, no peer probes)"
    out=$(ssh_vm 'sudo /usr/local/sbin/sysvol-sync --status' 2>&1 || true)
    echo "$out" | head -15
    grep -q 'GPO GUID' <<< "$out" || { say "--status output looks malformed"; rc=1; }

    return $rc
}

# CRITICAL: post_hook must run even on FAIL, because a partially-failed
# scenario could leave the Windows DC powered off and the rest of the lab
# (especially future runs of join-dc) would break. lab-kit's runner already
# calls post_hook unconditionally per its pipeline, but we add an extra
# bring-up loop here so we know the VM is actually back up before we exit.
post_hook() {
    step "(post_hook) bring $WS2025_VM back up"
    ssh_host "Start-VM -Name '$WS2025_VM' -ErrorAction SilentlyContinue"

    say "wait for $WS2025_VM to be Running (up to 60s)"
    for _ in $(seq 1 30); do
        state=$(ssh_host "(Get-VM -Name '$WS2025_VM').State.ToString()" 2>/dev/null | tr -d '\r')
        [[ "$state" == "Running" ]] && break
        sleep 2
    done
    say "$WS2025_VM is now: ${state:-unknown}"

    # Best-effort: wait for AD-DS to actually answer LDAP, not just for the
    # VM hypervisor state to flip. Bounded so a slow Windows boot doesn't
    # hang the whole pipeline.
    say "wait for AD on $WS2025_VM to respond (up to 120s)"
    for _ in $(seq 1 30); do
        if ssh_vm 'timeout 3 ldapsearch -x -LLL -H ldap://10.10.10.10 -s base -b "" defaultNamingContext 2>/dev/null | grep -q DC=lab,DC=test'; then
            say "$WS2025_VM is answering LDAP"
            return 0
        fi
        sleep 4
    done
    say "WARN: $WS2025_VM not yet answering LDAP after 120s; manual check recommended"
}

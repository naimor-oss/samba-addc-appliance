#!/usr/bin/env bats

setup() {
    export SAMBA_SCONFIG_SOURCE_ONLY=1
    export SAMBA_SMB_CONF="${BATS_TEST_TMPDIR}/smb.conf"
    export SAMBA_DFS_SAM_DB="${BATS_TEST_TMPDIR}/sam.ldb"
    export SAMBA_DFS_ROOT_PROXY_UNIT="${BATS_TEST_TMPDIR}/samba-dfs-root-proxy-sync.service"
    export SAMBA_DFS_ROOT_PROXY_TIMER="${BATS_TEST_TMPDIR}/samba-dfs-root-proxy-sync.timer"
    export SAMBA_DFS_ROOT_PROXY_LOCK="${BATS_TEST_TMPDIR}/samba-dfs-root-proxy-sync.lock"
    export LDB_FIXTURE="${BATS_TEST_TMPDIR}/dfs-roots.ldif"
    export CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"

    cat > "$SAMBA_SMB_CONF" <<'EOF'
[global]
    realm = NAIMOR.NAIMORINC.COM

[sysvol]
    path = /var/lib/samba/sysvol

[netlogon]
    path = /var/lib/samba/sysvol/naimor.naimorinc.com/scripts
EOF

    source "${BATS_TEST_DIRNAME}/../samba-sconfig.sh"
    eval "$(declare -f mock_dfs_render_targets | sed '1s/mock_dfs_render_targets/_dfs_render_targets/')"
}

teardown() {
    unset SAMBA_SCONFIG_SOURCE_ONLY SAMBA_SMB_CONF SAMBA_DFS_SAM_DB \
          SAMBA_DFS_ROOT_PROXY_UNIT SAMBA_DFS_ROOT_PROXY_TIMER \
          SAMBA_DFS_ROOT_PROXY_LOCK LDB_FIXTURE CALL_LOG
}

ldbsearch() {
    cat "$LDB_FIXTURE"
}

hostname() {
    case "${1:-}" in
        -s) printf '%s\n' 'mal-dc2' ;;
        -f) printf '%s\n' 'mal-dc2.naimor.naimorinc.com' ;;
        *)  printf '%s\n' 'mal-dc2' ;;
    esac
}

testparm() {
    printf 'testparm %s\n' "$*" >> "$CALL_LOG"
}

smbcontrol() {
    printf 'smbcontrol %s\n' "$*" >> "$CALL_LOG"
}

systemctl() {
    printf 'systemctl %s\n' "$*" >> "$CALL_LOG"
}

mock_dfs_render_targets() {
    case "$1" in
        ROOT_CNC)
            printf '%s\n' \
                $'siteCostNormal\t10\tonline\t\\\\SERVER.naimor.naimorinc.com\\CNCFiles' \
                $'siteCostNormal\t0\tonline\t\\\\FILES.naimor.naimorinc.com\\CNCFiles' \
                $'globalLow\t0\tonline\t\\\\mal-dc2.naimor.naimorinc.com\\CNCFiles'
            ;;
        ROOT_PF)
            printf '%s\n' \
                $'siteCostNormal\t0\tonline\t\\\\FILES.naimor.naimorinc.com\\PF$' \
                $'siteCostNormal\t0\toffline\t\\\\OLD.naimor.naimorinc.com\\PF$'
            ;;
        ROOT_SHARED)
            printf '%s\n' \
                $'siteCostNormal\t0\tonline\t\\\\FILES.naimor.naimorinc.com\\Shared'
            ;;
        ROOT_BAD)
            printf '%s\n' \
                $'siteCostNormal\t0\tonline\t\\\\FILES.naimor.naimorinc.com\\Shared\\extra'
            ;;
        *) return 3 ;;
    esac
}

write_v1_root_record() {
    local name="$1" target="$2"
    cat >> "$LDB_FIXTURE" <<EOF
dn: CN=${name},CN=Dfs-Configuration,CN=System,DC=naimor,DC=naimorinc,DC=com
objectClass: fTDfs
name: ${name}
remoteServerName: ${target}
remoteServerName: *

EOF
}

write_root_record() {
    local name="$1" blob="$2"
    cat >> "$LDB_FIXTURE" <<EOF
dn: CN=${name},CN=${name},CN=Dfs-Configuration,CN=System,DC=naimor,DC=naimorinc,DC=com
cn: ${name}
msDFS-TargetListv2:: ${blob}

EOF
}

@test "domain root sync creates proxy shares and excludes offline and local targets" {
    : > "$LDB_FIXTURE"
    write_root_record CNCFiles ROOT_CNC
    write_root_record 'PF$' ROOT_PF

    run _dfs_sync_domain_root_proxies

    [ "$status" -eq 0 ]
    grep -Fq '[CNCFiles]' "$SAMBA_SMB_CONF"
    grep -Fq '    msdfs root = yes' "$SAMBA_SMB_CONF"
    grep -Fq '    msdfs proxy = \FILES.naimor.naimorinc.com\CNCFiles,\SERVER.naimor.naimorinc.com\CNCFiles' "$SAMBA_SMB_CONF"
    grep -Fq '[PF$]' "$SAMBA_SMB_CONF"
    grep -Fq '    msdfs proxy = \FILES.naimor.naimorinc.com\PF$' "$SAMBA_SMB_CONF"
    ! grep -Fq 'mal-dc2.naimor.naimorinc.com' "$SAMBA_SMB_CONF"
    ! grep -Fq 'OLD.naimor.naimorinc.com' "$SAMBA_SMB_CONF"
    [ "$(grep -Fc "$DFS_ROOT_PROXY_BEGIN" "$SAMBA_SMB_CONF")" -eq 1 ]
    grep -Fq 'smbcontrol all reload-config' "$CALL_LOG"
}

@test "domain root sync converges idempotently and removes stale managed roots" {
    : > "$LDB_FIXTURE"
    write_root_record CNCFiles ROOT_CNC
    write_root_record 'PF$' ROOT_PF
    _dfs_sync_domain_root_proxies

    : > "$LDB_FIXTURE"
    write_root_record CNCFiles ROOT_CNC
    _dfs_sync_domain_root_proxies

    [ "$(grep -Fc "$DFS_ROOT_PROXY_BEGIN" "$SAMBA_SMB_CONF")" -eq 1 ]
    [ "$(grep -Fc '[CNCFiles]' "$SAMBA_SMB_CONF")" -eq 1 ]
    ! grep -Fq '[PF$]' "$SAMBA_SMB_CONF"
}

@test "invalid domain root metadata preserves the last known-good configuration" {
    cat >> "$SAMBA_SMB_CONF" <<EOF

${DFS_ROOT_PROXY_BEGIN}
[Existing]
    msdfs root = yes
    msdfs proxy = \FILES.naimor.naimorinc.com\Existing
${DFS_ROOT_PROXY_END}
EOF
    cp "$SAMBA_SMB_CONF" "${SAMBA_SMB_CONF}.before"
    : > "$LDB_FIXTURE"
    write_root_record Shared ROOT_BAD

    run _dfs_sync_domain_root_proxies

    [ "$status" -ne 0 ]
    cmp -s "$SAMBA_SMB_CONF" "${SAMBA_SMB_CONF}.before"
    [[ "$output" == *"invalid target"* ]]
}

@test "operator-authored share collision is reported and not overwritten" {
    cat >> "$SAMBA_SMB_CONF" <<'EOF'

[Shared]
    path = /srv/samba/shared
EOF
    cp "$SAMBA_SMB_CONF" "${SAMBA_SMB_CONF}.before"
    : > "$LDB_FIXTURE"
    write_root_record Shared ROOT_SHARED

    run _dfs_sync_domain_root_proxies

    [ "$status" -ne 0 ]
    cmp -s "$SAMBA_SMB_CONF" "${SAMBA_SMB_CONF}.before"
    [[ "$output" == *"existing share [Shared]"* ]]
}

@test "malformed managed block markers are never used as rewrite boundaries" {
    cat >> "$SAMBA_SMB_CONF" <<EOF

${DFS_ROOT_PROXY_END}
[OperatorShare]
    path = /srv/samba/operator
${DFS_ROOT_PROXY_BEGIN}
EOF
    cp "$SAMBA_SMB_CONF" "${SAMBA_SMB_CONF}.before"
    : > "$LDB_FIXTURE"

    run _dfs_sync_domain_root_proxies

    [ "$status" -ne 0 ]
    cmp -s "$SAMBA_SMB_CONF" "${SAMBA_SMB_CONF}.before"
    [[ "$output" == *"markers are reversed"* ]]
}

@test "zero domain roots removes stale managed proxies without touching base shares" {
    cat >> "$SAMBA_SMB_CONF" <<EOF

${DFS_ROOT_PROXY_BEGIN}
[OldRoot]
    msdfs root = yes
    msdfs proxy = \FILES.naimor.naimorinc.com\OldRoot
${DFS_ROOT_PROXY_END}
EOF
    : > "$LDB_FIXTURE"

    run _dfs_sync_domain_root_proxies

    [ "$status" -eq 0 ]
    ! grep -Fq "$DFS_ROOT_PROXY_BEGIN" "$SAMBA_SMB_CONF"
    grep -Fq '[sysvol]' "$SAMBA_SMB_CONF"
    grep -Fq '[netlogon]' "$SAMBA_SMB_CONF"
}

@test "legacy domain-v1 roots are proxied from remoteServerName targets" {
    : > "$LDB_FIXTURE"
    write_v1_root_record Legacy '\\FILES.naimor.naimorinc.com\Legacy'

    run _dfs_sync_domain_root_proxies

    [ "$status" -eq 0 ]
    grep -Fq '[Legacy]' "$SAMBA_SMB_CONF"
    grep -Fq '    msdfs proxy = \FILES.naimor.naimorinc.com\Legacy' "$SAMBA_SMB_CONF"
}

@test "zero domain roots do not reformat an untouched smb.conf" {
    cp "$SAMBA_SMB_CONF" "${SAMBA_SMB_CONF}.before"
    : > "$LDB_FIXTURE"

    run _dfs_sync_domain_root_proxies

    [ "$status" -eq 0 ]
    cmp -s "$SAMBA_SMB_CONF" "${SAMBA_SMB_CONF}.before"
}

@test "root proxy timer is installed for automatic convergence" {
    run _dfs_install_root_proxy_timer

    [ "$status" -eq 0 ]
    grep -Fq 'ExecStart=/usr/local/sbin/samba-sconfig dfs-root-sync' "$SAMBA_DFS_ROOT_PROXY_UNIT"
    grep -Fq 'ReadWritePaths=/etc/samba /run' "$SAMBA_DFS_ROOT_PROXY_UNIT"
    grep -Fq 'OnUnitActiveSec=5min' "$SAMBA_DFS_ROOT_PROXY_TIMER"
    grep -Fq 'systemctl enable --now samba-dfs-root-proxy-sync.timer' "$CALL_LOG"
}

@test "safe Windows namespace names with spaces are accepted" {
    run _dfs_root_name_validate 'Shop Programs'

    [ "$status" -eq 0 ]
}

@test "DFS targets reject subpaths even when appliance-core accepts them" {
    appcore_id_unc_validate() {
        return 0
    }

    run _dfs_validate_target_unc '\\FILES.naimor.naimorinc.com\Shared\extra'

    [ "$status" -ne 0 ]
}

#!/usr/bin/env bats
# Code-review session plan 05: DFS and SYSVOL-sync settings and the
# first-boot detection cache are parsed as data, never sourced.

setup() {
    export SAMBA_SCONFIG_SOURCE_ONLY=1
    export SAMBA_APPCORE_KVSTATE="${BATS_TEST_DIRNAME}/../../appliance-core/lib/kvstate.sh"
    export SAMBA_DFS_CONF="${BATS_TEST_TMPDIR}/dfs-update.conf"
    export SAMBA_SYSVOL_SYNC_CONF="${BATS_TEST_TMPDIR}/sysvol-sync.conf"
    export PWNED="${BATS_TEST_TMPDIR}/pwned"
    source "${BATS_TEST_DIRNAME}/../samba-sconfig.sh"
    PREPARE="${BATS_TEST_DIRNAME}/../prepare-image.sh"
}

@test "DFS settings round-trip a prefer-regex with backslashes and a hidden namespace" {
    dfs_conf_save /srv/samba/dfs_root Public 'Public$ Internal' '^\\\\WIN-'
    dfs_conf_load
    [ "$DFS_ROOT" = /srv/samba/dfs_root ]
    [ "$DFS_NAMESPACES" = 'Public$ Internal' ]
    [ "$DFS_PREFER" = '^\\\\WIN-' ]
    [ "$(dfs_conf_root)" = /srv/samba/dfs_root ]
}

@test "a hostile DFS config is never executed and fails closed" {
    printf 'DFS_ROOT="/srv/x"$(touch %s)\nDFS_SHARE="Public"\n' "$PWNED" > "$SAMBA_DFS_CONF"
    run dfs_conf_load
    [ "$status" -ne 0 ]
    [[ "$output" == *malformed* ]]
    run _dfs_run_update
    [ "$status" -eq 1 ]
    [ -z "$(dfs_conf_root)" ]
    [ ! -e "$PWNED" ]
}

@test "dfs-configure keeps root and share and stores namespaces as data" {
    root="${BATS_TEST_TMPDIR}/dfs"
    dfs_conf_save "$root" Public '' ''
    SC_DFS_PREFER='^\\\\WIN-' cli_dfs_configure Ops 'Eng$'
    dfs_conf_load
    [ "$DFS_ROOT" = "$root" ]
    [ "$DFS_SHARE" = Public ]
    [ "$DFS_NAMESPACES" = 'Ops Eng$' ]
    [ "$DFS_PREFER" = '^\\\\WIN-' ]
    [ -d "$root/Ops" ]
}

@test "SYSVOL sync status reports a malformed config without running it" {
    printf 'SYNC_INTERVAL="15"\nPREFERRED_DCS="dc1"`touch %s`\n' "$PWNED" > "$SAMBA_SYSVOL_SYNC_CONF"
    info_text() { printf '%s' "$2"; }
    _tui_show() { printf '%s' "$2"; }
    whiptail() { printf '%s' "$*"; }
    run show_sync_status
    [[ "$output" == *malformed* ]]
    [ ! -e "$PWNED" ]
}

@test "generated scripts never source settings or the detection cache" {
    ! grep -nE '(source|\.) "\$(CONF|DET|DETECT_FILE|DFS_CONF|SYSVOL_SYNC_CONF)"' "$PREPARE"
    ! grep -nE 'source "\$(DFS_CONF|SYSVOL_SYNC_CONF)"' "${BATS_TEST_DIRNAME}/../samba-sconfig.sh"
    grep -q 'appcore_kv_load "$CONF" SYNC_INTERVAL PREFERRED_DCS EXCLUDE_DCS' "$PREPARE"
}

@test "the login banner reads a hostile detection cache as inert text" {
    body=$(awk '/^cat > \/etc\/update-motd.d\/15-samba-net-status/ {f=1; next} /^MOTDEOF$/ {f=0} f' "$PREPARE")
    [ -n "$body" ]
    printf 'SAMBA_DET_AD_DC="x$(touch %s)"\nAPPCORE_DET_EFFECTIVE_DOMAIN="lab.example"\n' "$PWNED" \
        > "${BATS_TEST_TMPDIR}/det.env"
    printf '%s\n' "$body" | sed "s|^DET=.*|DET=${BATS_TEST_TMPDIR}/det.env|" > "${BATS_TEST_TMPDIR}/motd"
    run sh "${BATS_TEST_TMPDIR}/motd"
    [ ! -e "$PWNED" ]
    [[ "$output" == *lab.example* ]]
    [[ "$output" != *'$('* ]]
}

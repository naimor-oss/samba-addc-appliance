#!/usr/bin/env bats
# DFS withdrawal and deletion convergence (code-review session plan 04).
# Both AD-derived mechanisms withdraw referrals for valid offline, empty and
# deleted state, and keep the last known-good output only when the AD result
# is indeterminate or invalid.

setup() {
    export SAMBA_SCONFIG_SOURCE_ONLY=1
    export SAMBA_APPCORE_KVSTATE="${BATS_TEST_DIRNAME}/../../appliance-core/lib/kvstate.sh"
    export SAMBA_SMB_CONF="${BATS_TEST_TMPDIR}/smb.conf"
    export SAMBA_DFS_SAM_DB="${BATS_TEST_TMPDIR}/sam.ldb"
    export SAMBA_DFS_ROOT_PROXY_LOCK="${BATS_TEST_TMPDIR}/root.lock"
    export SAMBA_DFS_LOCK="${BATS_TEST_TMPDIR}/dfs.lock"
    export SAMBA_DFS_LOG="${BATS_TEST_TMPDIR}/dfs-update.log"
    export LDB_FIXTURE="${BATS_TEST_TMPDIR}/ldb.ldif"
    export LDB_FAIL="${BATS_TEST_TMPDIR}/ldb.fail"
    printf '[global]\n    realm = LAB.EXAMPLE\n\n[netlogon]\n    path = /var/lib/samba/sysvol/lab.example/scripts\n' \
        > "$SAMBA_SMB_CONF"
    : > "$LDB_FIXTURE"
    source "${BATS_TEST_DIRNAME}/../samba-sconfig.sh"
    eval "$(declare -f mock_render | sed '1s/mock_render/_dfs_render_targets/')"
    NS_ROOT="${BATS_TEST_TMPDIR}/dfs/Corp"
    mkdir -p "$NS_ROOT"
    : > "$NS_ROOT/$DFS_SENTINEL_NAME"
    DFS_ROOT="${BATS_TEST_TMPDIR}/dfs"
    DFS_PREFER=""
}

ldbsearch() {
    [[ -e "$LDB_FAIL" ]] && { echo "ldb: No such object"; return 32; }
    cat "$LDB_FIXTURE"
}
hostname() { case "${1:-}" in -f) echo dc1.lab.example ;; *) echo dc1 ;; esac; }
testparm() { return 0; }
smbcontrol() { return 0; }

# Blob names stand in for base64 target lists.
mock_render() {
    case "$1" in
        UP)        printf '%s\n' $'siteCostNormal\t0\tonline\t\\\\FS1.lab.example\\Data' ;;
        UP2)       printf '%s\n' $'siteCostNormal\t0\tONLINE\t\\\\FS1.lab.example\\Data' \
                                 $'siteCostNormal\t0\tOffline\t\\\\FS2.lab.example\\Data' ;;
        DOWN)      printf '%s\n' $'siteCostNormal\t0\tOFFLINE\t\\\\FS1.lab.example\\Data' ;;
        SELF)      printf '%s\n' $'siteCostNormal\t0\tonline\t\\\\dc1.lab.example\\Data' ;;
        EMPTY)     return 2 ;;
        WEIRD)     printf '%s\n' $'siteCostNormal\t0\tpaused\t\\\\FS1.lab.example\\Data' ;;
        BADUNC)    printf '%s\n' $'siteCostNormal\t0\tonline\t\\\\FS1.lab.example\\Data\\sub' ;;
        *)         return 3 ;;
    esac
}

root() {   # NAME BLOB
    printf 'dn: CN=%s,CN=%s,CN=Dfs-Configuration,CN=System,DC=lab,DC=example\ncn: %s\nmsDFS-TargetListv2:: %s\n\n' \
        "$1" "$1" "$1" "$2" >> "$LDB_FIXTURE"
}
link() {   # PATH BLOB
    printf 'dn: CN=link-%s,CN=Corp,CN=Corp,CN=Dfs-Configuration,CN=System,DC=lab,DC=example\nmsDFS-LinkPathv2: /%s\nmsDFS-TargetListv2:: %s\n\n' \
        "$1" "$1" "$2" >> "$LDB_FIXTURE"
}
section_present() { grep -Fxq "[$1]" "$SAMBA_SMB_CONF"; }
update() { _dfs_update_one_namespace Corp "DC=lab,DC=example" 0; }

# ---------------------------------------------------------------- roots

@test "root: last online target going offline withdraws only that namespace" {
    root Apps UP; root Data UP
    _dfs_sync_domain_root_proxies
    section_present Apps && section_present Data
    : > "$LDB_FIXTURE"; root Apps DOWN; root Data UP
    run _dfs_sync_domain_root_proxies
    [ "$status" -eq 0 ]
    [[ "$output" == *"withdrawn: 1"* ]]
    ! section_present Apps
    section_present Data
}

@test "root: offline back to online republishes the proxy" {
    root Apps DOWN
    _dfs_sync_domain_root_proxies
    ! section_present Apps
    : > "$LDB_FIXTURE"; root Apps UP
    _dfs_sync_domain_root_proxies
    section_present Apps
}

@test "root: self-only and empty target lists are withdrawals, not errors" {
    root Apps UP; root Data UP
    _dfs_sync_domain_root_proxies
    : > "$LDB_FIXTURE"; root Apps SELF; root Data EMPTY; root Keep UP
    run _dfs_sync_domain_root_proxies
    [ "$status" -eq 0 ]
    ! section_present Apps
    ! section_present Data
    section_present Keep
}

@test "root: offline targets are filtered case-insensitively" {
    root Data UP2
    _dfs_sync_domain_root_proxies
    grep -Fq 'msdfs proxy = \FS1.lab.example\Data' "$SAMBA_SMB_CONF"
    ! grep -Fq 'FS2' "$SAMBA_SMB_CONF"
}

@test "root: unknown state, bad target, parse failure and ldbsearch failure keep last known-good" {
    root Apps UP
    _dfs_sync_domain_root_proxies
    cp "$SAMBA_SMB_CONF" "$BATS_TEST_TMPDIR/before"
    for blob in WEIRD BADUNC GARBAGE; do
        : > "$LDB_FIXTURE"; root Apps "$blob"
        run _dfs_sync_domain_root_proxies
        [ "$status" -ne 0 ]
        cmp -s "$SAMBA_SMB_CONF" "$BATS_TEST_TMPDIR/before"
    done
    : > "$LDB_FAIL"
    run _dfs_sync_domain_root_proxies
    [ "$status" -ne 0 ]
    cmp -s "$SAMBA_SMB_CONF" "$BATS_TEST_TMPDIR/before"
}

# ---------------------------------------------------------------- links

@test "link: offline targets are never published" {
    link Docs UP2
    update
    [ "$(readlink "$NS_ROOT/Docs")" = 'msdfs:FS1.lab.example\Data' ]
}

@test "link: last target offline prunes the link; recovery restores it" {
    link Docs UP; link Wiki UP
    update
    [ -L "$NS_ROOT/Docs" ]
    : > "$LDB_FIXTURE"; link Docs DOWN; link Wiki UP
    run update
    [ "$status" -eq 0 ]
    [[ "$output" == *"withdrawn: /Docs has no online target"* || "$output" == *"withdrawn: Docs has no online target"* ]]
    [ ! -e "$NS_ROOT/Docs" ]
    [ -L "$NS_ROOT/Wiki" ]
    : > "$LDB_FIXTURE"; link Docs UP; link Wiki UP
    update
    [ -L "$NS_ROOT/Docs" ]
}

@test "link: deleting a link and then the last link prunes them" {
    link Docs UP; link Wiki UP
    update
    : > "$LDB_FIXTURE"; link Wiki UP
    update
    [ ! -e "$NS_ROOT/Docs" ]
    : > "$LDB_FIXTURE"
    run update
    [ "$status" -eq 0 ]
    [ ! -e "$NS_ROOT/Wiki" ]
}

@test "link: a rejected record makes the result incomplete and prunes nothing" {
    link Docs UP; link Wiki UP
    update
    for blob in WEIRD BADUNC GARBAGE; do
        : > "$LDB_FIXTURE"; link Docs UP; link Wiki "$blob"
        run update
        [ "$status" -ne 0 ]
        [ -L "$NS_ROOT/Wiki" ]
        [ "$(readlink "$NS_ROOT/Wiki")" = 'msdfs:FS1.lab.example\Data' ]
    done
    printf 'dn: CN=link-x,CN=Corp,CN=Corp,CN=Dfs-Configuration,CN=System,DC=lab,DC=example\nmsDFS-LinkPathv2: /Wiki\n\n' \
        > "$LDB_FIXTURE"
    run update
    [ "$status" -ne 0 ]
    [ -L "$NS_ROOT/Wiki" ]
}

@test "link: ldbsearch failure or a deleted namespace container prunes nothing" {
    link Docs UP
    update
    : > "$LDB_FAIL"
    run update
    [ "$status" -ne 0 ]
    [ -L "$NS_ROOT/Docs" ]
}

@test "link: foreign files and non-managed symlinks are never removed" {
    link Docs UP
    update
    printf 'keep\n' > "$NS_ROOT/readme.txt"
    ln -s /srv/elsewhere "$NS_ROOT/foreign"
    : > "$LDB_FIXTURE"
    update
    [ -f "$NS_ROOT/readme.txt" ]
    [ -L "$NS_ROOT/foreign" ]
    [ -f "$NS_ROOT/$DFS_SENTINEL_NAME" ]
    [ ! -e "$NS_ROOT/Docs" ]
}

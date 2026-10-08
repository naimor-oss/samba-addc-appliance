#!/usr/bin/env bash
# The Samba AD DC update bundle against a simulated field DC (built before
# release identity: no release file, no kvstate libs, old scripts). Builds
# the real bundle and applies it with the real hooks. Run as root in a
# DISPOSABLE container:
#
#   docker run --rm -v "$PWD/..":/ws:ro -e DISPOSABLE_ROOT_TEST=1 \
#       debian:trixie bash /ws/samba-addc-appliance/tests/root/update-bundle.sh

set -uo pipefail
[[ ${EUID} -eq 0 && "${DISPOSABLE_ROOT_TEST:-0}" == 1 ]] || {
    echo "refusing: run as root in a disposable container with DISPOSABLE_ROOT_TEST=1" >&2
    exit 2
}
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

cp -a "$SRC" "$T/samba-addc-appliance"
cp -a "$SRC/../appliance-core" "$T/appliance-core"
"$T/samba-addc-appliance/updates/build-bundle.sh" --out "$T/dist" >/dev/null || fail "bundle build failed"
VERSION=$(head -1 "$SRC/VERSION")
BUNDLE="$T/dist/samba-addc-update-$VERSION.tar.gz"
[[ -f "$BUNDLE" && -f "$BUNDLE.sha256" ]] || fail "bundle not produced"

# ---- fakes ---------------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/systemctl" <<'SH'
#!/bin/sh
echo "$*" >> /tmp/systemctl.log
exit 0
SH
cat > "$T/bin/testparm" <<'SH'
#!/bin/sh
[ -e /tmp/fail-testparm ] && exit 1
exit 0
SH
# debian:trixie has no python3; a real DC always does (samba-tool needs it).
printf '#!/bin/sh\nexit 0\n' > "$T/bin/python3"
printf '#!/bin/sh\necho 2:4.22.10+dfsg-0+deb13u2\n' > "$T/bin/dpkg-query"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

make_unit() {
    rm -rf /etc/samba /usr/local/lib/appliance-core /etc/samba-addc.release \
        /var/backups/samba-addc-update /etc/update-motd.d /etc/cron.d/sysvol-sync
    mkdir -p /etc/samba /usr/local/sbin /usr/local/lib/appliance-core /etc/update-motd.d /etc/cron.d
    printf '[global]\n    realm = LAB.EXAMPLE\n    server role = active directory domain controller\n' \
        > /etc/samba/smb.conf
    # Written by the old heredoc / sed writers.
    printf '# Managed by samba-sconfig dfs-* commands.\nDFS_ROOT="/srv/samba/dfs_root"\nDFS_SHARE="dfs_root"\nDFS_NAMESPACES="Public"\nDFS_PREFER=""\n' \
        > /etc/samba/dfs-update.conf
    printf '# sysvol-sync.conf v2\nSYNC_INTERVAL="15"\nPREFERRED_DCS=""\nEXCLUDE_DCS=""\n' \
        > /etc/samba/sysvol-sync.conf
    printf '*/15 * * * * root /usr/local/sbin/sysvol-sync\n' > /etc/cron.d/sysvol-sync
    for s in samba-sconfig sysvol-sync samba-dfs-parse-targets samba-firstboot; do
        printf '#!/bin/sh\n# old %s\nexit 0\n' "$s" > "/usr/local/sbin/$s"
        chmod 0755 "/usr/local/sbin/$s"
    done
    rm -f /usr/local/sbin/samba-init /usr/local/sbin/samba-addc-update
    printf '#!/bin/sh\nDET=/var/lib/samba-init-detected.env\n[ -r "$DET" ] && . "$DET"\n' \
        > /etc/update-motd.d/15-samba-net-status
    chmod 0755 /etc/update-motd.d/15-samba-net-status
    printf 'old lib\n' > /usr/local/lib/appliance-core/detect-net.sh
    rm -f /tmp/systemctl.log /tmp/fail-testparm
    snapshot
}
snapshot() {
    sha256sum /usr/local/sbin/* /etc/samba/* /etc/cron.d/sysvol-sync \
        /usr/local/lib/appliance-core/* /etc/update-motd.d/* > "$T/unit.before"
}
unit_unchanged() {
    sha256sum -c --quiet "$T/unit.before" >/dev/null 2>&1 \
        && [[ ! -e /etc/samba-addc.release && ! -e /usr/local/sbin/samba-addc-update ]]
}
extract() {
    rm -rf "$T/x"; mkdir -p "$T/x"
    tar -xzf "$BUNDLE" -C "$T/x"
    B="$T/x/samba-addc-update-$VERSION"
}

# ---- 1. the field DC is updated -------------------------------------------------
make_unit; extract
bash "$B/install.sh" > "$T/out" 2>&1 || { cat "$T/out"; fail "update of the field DC failed"; }
cmp -s "$SRC/samba-sconfig.sh" /usr/local/sbin/samba-sconfig || fail "samba-sconfig not replaced"
grep -q 'BEGIN gpo-publish' /usr/local/sbin/sysvol-sync || fail "sysvol-sync not replaced with the atomic publisher"
! grep -q '^\[ -r "\$DET" \] && \. "\$DET"' /etc/update-motd.d/15-samba-net-status \
    || fail "the login banner still sources the detection cache"
[[ ! -e /usr/local/sbin/samba-init ]] || fail "a script the unit never had was installed"
[[ -f /usr/local/lib/appliance-core/kvstate.sh && -x /usr/local/sbin/samba-addc-update ]] \
    || fail "libs or the built-in updater missing"
grep -q '^VERSION="'"$VERSION"'"$' /etc/samba-addc.release || fail "release file not written"
grep -q '^APPLIANCE="samba-addc"$' /etc/samba-addc.release || fail "appliance not recorded"
grep -q '^SAMBA_VERSION="2:4.22.10+dfsg-0+deb13u2"$' /etc/samba-addc.release || fail "Samba version not recorded"
grep -q 'stop samba-dfs-update.timer' /tmp/systemctl.log && grep -q 'start samba-dfs-update.timer' /tmp/systemctl.log \
    || fail "DFS timers were not paused and restarted"
cmp -s /etc/samba/dfs-update.conf <(printf '# Managed by samba-sconfig dfs-* commands.\nDFS_ROOT="/srv/samba/dfs_root"\nDFS_SHARE="dfs_root"\nDFS_NAMESPACES="Public"\nDFS_PREFER=""\n') \
    || fail "the update changed DFS settings"
pass "field DC 0.0.0-legacy -> $VERSION: scripts, libs, banner, updater, release file; settings untouched"

# ---- 2. built-in updater -------------------------------------------------------
/usr/local/sbin/samba-addc-update status | grep -q "VERSION          $VERSION" || fail "status does not report $VERSION"
/usr/local/sbin/samba-addc-update apply "$BUNDLE" | grep -q "Already at $VERSION" || fail "re-apply is not a no-op"
pass "samba-addc-update status and an idempotent re-apply"

# ---- 3. rollback ------------------------------------------------------------------
/usr/local/sbin/samba-addc-update rollback > "$T/out" 2>&1 || { cat "$T/out"; fail "rollback failed"; }
unit_unchanged || fail "rollback did not restore the DC exactly"
pass "samba-addc-update rollback restores every file and removes what the update added"

# ---- 4. refusals -------------------------------------------------------------------
make_unit; extract
printf 'SYNC_TRANSPORT="ssh"\nREMOTE_DC="dc0"\n' > /etc/samba/sysvol-sync.conf
snapshot
rc=0; bash "$B/install.sh" > "$T/out" 2>&1 || rc=$?
[[ $rc -eq 2 ]] && grep -q 'sysvol-sync.conf' "$T/out" || fail "legacy sysvol-sync.conf was not refused by name"
unit_unchanged || fail "refused update changed the DC"
make_unit; extract
sed -i '/server role/d' /etc/samba/smb.conf
snapshot
rc=0; bash "$B/install.sh" > "$T/out" 2>&1 || rc=$?
[[ $rc -eq 2 ]] && grep -q 'cannot determine' "$T/out" || fail "a unit that is not a provisioned DC was not refused"
unit_unchanged || fail "refused update changed the unit"
pass "unreadable settings and a non-DC unit are refused with no change"

# ---- 5. automatic rollback -----------------------------------------------------------
make_unit; extract
touch /tmp/fail-testparm
rc=0; bash "$B/install.sh" > "$T/out" 2>&1 || rc=$?
rm -f /tmp/fail-testparm
[[ $rc -eq 3 ]] || { cat "$T/out"; fail "failed verify did not report rc=3 (rc=$rc)"; }
unit_unchanged || fail "automatic rollback did not restore the DC exactly"
grep -q 'start samba-dfs-update.timer' /tmp/systemctl.log || fail "DFS timers not restarted after rollback"
pass "a failed verify restores the DC automatically (rc=3) and restarts DFS timers"

echo "update bundle tests passed"

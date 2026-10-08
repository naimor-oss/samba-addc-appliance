# shellcheck shell=bash
# Samba AD DC update hooks for the appliance-core update framework
# (appliance-core docs/lib-update.md). Sourced by the bundle's install.sh and
# saved into every backup for rollback.
#
# Policy: replace the appliance's own scripts and the vendored appliance-core
# libs. Never touch the AD database (/var/lib/samba) or Debian packages
# (Samba security updates arrive through apt). A running sysvol-sync is
# waited for, and DFS timers are paused, while files are replaced.

SAMBA_UPD_SBIN="${SAMBA_UPDATE_SBIN:-/usr/local/sbin}"
SAMBA_UPD_LIBDIR="${SAMBA_UPDATE_LIBDIR:-/usr/local/lib/appliance-core}"
SAMBA_UPD_ETC="${SAMBA_UPDATE_ETC:-/etc/samba}"
SAMBA_UPD_RUN_STATE="${SAMBA_UPDATE_RUN_STATE:-/run/samba-addc-update.state}"
SAMBA_UPD_SYNC_LOCK="${SAMBA_UPDATE_SYNC_LOCK:-/run/sysvol-sync.lock}"
SAMBA_UPD_REQUIRED=(samba-sconfig sysvol-sync samba-dfs-parse-targets samba-addc-update)
SAMBA_UPD_OPTIONAL=(samba-firstboot samba-init)
SAMBA_UPD_MOTD=(15-samba-net-status)
SAMBA_UPD_TIMERS=(samba-dfs-update.timer samba-dfs-root-proxy-sync.timer)

# A DC built before release identity has no marker of its own. It is
# accepted as 0.0.0-legacy only when it is unmistakably a provisioned DC
# built by this repo; anything else is refused by the runner.
update_detect_version() {
    [[ -x "$SAMBA_UPD_SBIN/samba-sconfig" && -f "$SAMBA_UPD_ETC/smb.conf" ]] || return 0
    grep -Eiq '^[[:space:]]*server role[[:space:]]*=[[:space:]]*active directory domain controller' \
        "$SAMBA_UPD_ETC/smb.conf" || return 0
    echo 0.0.0-legacy
}

update_backup_paths() {
    local s
    printf '%s\n' "$SAMBA_UPD_ETC/smb.conf" "$SAMBA_UPD_ETC/dfs-update.conf" \
        "$SAMBA_UPD_ETC/sysvol-sync.conf" "$SAMBA_UPD_LIBDIR" /etc/cron.d/sysvol-sync
    for s in "${SAMBA_UPD_REQUIRED[@]}" "${SAMBA_UPD_OPTIONAL[@]}"; do
        printf '%s\n' "$SAMBA_UPD_SBIN/$s"
    done
    printf '/etc/update-motd.d/%s\n' "${SAMBA_UPD_MOTD[@]}"
}

# Settings files must parse with the new strict parser, or DFS updates and
# SYSVOL sync would stop after the update. Refuse instead, naming the file.
_samba_settings_problems() {
    local bad=""
    if [[ -e "$SAMBA_UPD_ETC/dfs-update.conf" ]]; then
        appcore_kv_load "$SAMBA_UPD_ETC/dfs-update.conf" DFS_ROOT DFS_SHARE DFS_NAMESPACES \
            DFS_PREFER >/dev/null 2>&1 || bad+=" $SAMBA_UPD_ETC/dfs-update.conf"
    fi
    if [[ -e "$SAMBA_UPD_ETC/sysvol-sync.conf" ]]; then
        appcore_kv_load "$SAMBA_UPD_ETC/sysvol-sync.conf" SYNC_INTERVAL PREFERRED_DCS \
            EXCLUDE_DCS >/dev/null 2>&1 || bad+=" $SAMBA_UPD_ETC/sysvol-sync.conf"
    fi
    printf '%s' "$bad"
}

update_preflight() {
    local c bad
    for c in systemctl testparm tar flock sha256sum python3; do
        command -v "$c" >/dev/null 2>&1 || { echo "required command missing: $c" >&2; return 1; }
    done
    [[ -f "$SAMBA_UPD_ETC/smb.conf" ]] || { echo "this DC is not provisioned" >&2; return 1; }
    bad=$(_samba_settings_problems)
    if [[ -n "$bad" ]]; then
        echo "settings the new parser cannot read (re-run the matching samba-sconfig configure step first):$bad" >&2
        return 1
    fi
}

update_stop() {
    local t
    : > "$SAMBA_UPD_RUN_STATE"
    for t in "${SAMBA_UPD_TIMERS[@]}"; do
        if systemctl is-active --quiet "$t" 2>/dev/null; then
            echo "$t" >> "$SAMBA_UPD_RUN_STATE"
            systemctl stop "$t" || return 1
        fi
    done
    # Wait for a running sysvol-sync to finish, then hold its lock until start.
    # An automatic rollback calls stop again while the lock is still held.
    [[ -n "${SAMBA_UPD_SYNC_FD:-}" ]] && return 0
    install -d -m 0755 "$(dirname "$SAMBA_UPD_SYNC_LOCK")"
    exec {SAMBA_UPD_SYNC_FD}>"$SAMBA_UPD_SYNC_LOCK"
    flock -w 900 "$SAMBA_UPD_SYNC_FD" || { echo "sysvol-sync did not finish within 15 minutes" >&2; return 1; }
}

update_apply() {
    local b="$1" s m
    install -d -m 0755 "$SAMBA_UPD_LIBDIR" "$SAMBA_UPD_SBIN" || return 1
    install -m 0644 "$b"/lib/*.sh "$SAMBA_UPD_LIBDIR/" || return 1
    install -m 0644 "$b/lib/VERSION" "$SAMBA_UPD_LIBDIR/VERSION" || return 1
    for s in "${SAMBA_UPD_REQUIRED[@]}"; do
        install -m 0755 "$b/payload/sbin/$s" "$SAMBA_UPD_SBIN/$s" || return 1
    done
    for s in "${SAMBA_UPD_OPTIONAL[@]}"; do
        if [[ -e "$SAMBA_UPD_SBIN/$s" ]]; then
            install -m 0755 "$b/payload/sbin/$s" "$SAMBA_UPD_SBIN/$s" || return 1
        else
            echo "  not installed on this unit, left absent: $s"
        fi
    done
    for m in "${SAMBA_UPD_MOTD[@]}"; do
        if [[ -e "/etc/update-motd.d/$m" ]]; then
            install -m 0755 "$b/payload/motd/$m" "/etc/update-motd.d/$m" || return 1
        fi
    done
    if [[ -f "$b/payload/appcore-commit" ]]; then
        install -m 0644 "$b/payload/appcore-commit" "$SAMBA_UPD_LIBDIR/COMMIT" || return 1
    fi
}

update_verify() {
    local s bad
    for s in samba-sconfig sysvol-sync samba-addc-update "${SAMBA_UPD_OPTIONAL[@]}"; do
        [[ -e "$SAMBA_UPD_SBIN/$s" ]] || continue
        bash -n "$SAMBA_UPD_SBIN/$s" || { echo "installed $s does not parse" >&2; return 1; }
    done
    python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' \
        "$SAMBA_UPD_SBIN/samba-dfs-parse-targets" \
        || { echo "installed samba-dfs-parse-targets does not compile" >&2; return 1; }
    testparm -s "$SAMBA_UPD_ETC/smb.conf" >/dev/null 2>&1 \
        || { echo "smb.conf fails testparm after the update" >&2; return 1; }
    bad=$(
        unset _APPCORE_KVSTATE_LOADED
        # shellcheck disable=SC1091
        source "$SAMBA_UPD_LIBDIR/kvstate.sh" && _samba_settings_problems
    )
    [[ -z "$bad" ]] || { echo "installed parser rejects:$bad" >&2; return 1; }
}

update_start() {
    local t
    if [[ -n "${SAMBA_UPD_SYNC_FD:-}" ]]; then
        exec {SAMBA_UPD_SYNC_FD}>&-
        SAMBA_UPD_SYNC_FD=""
    fi
    systemctl daemon-reload || return 1
    while IFS= read -r t; do
        [[ -n "$t" ]] && { systemctl start "$t" || return 1; }
    done < <(cat "$SAMBA_UPD_RUN_STATE" 2>/dev/null)
    rm -f "$SAMBA_UPD_RUN_STATE"
}

update_release_fields() {
    local v
    v=$(dpkg-query -W -f='${Version}' samba 2>/dev/null) && echo "SAMBA_VERSION $v"
    [[ -r "$SAMBA_UPD_LIBDIR/VERSION" ]] && echo "APPCORE_VERSION $(head -1 "$SAMBA_UPD_LIBDIR/VERSION")"
    [[ -r "$SAMBA_UPD_LIBDIR/COMMIT" ]] && echo "APPCORE_COMMIT $(head -1 "$SAMBA_UPD_LIBDIR/COMMIT")"
    return 0
}

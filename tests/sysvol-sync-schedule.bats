#!/usr/bin/env bats
# The SYSVOL puller runs from a systemd timer, not /etc/cron.d (the image has
# no cron, so a cron schedule could be written and never fire). Join,
# provision and the update bundle call sysvol_sync_schedule; it must keep a
# stored interval, use the default without writing settings, and fail closed
# on a malformed settings file.

setup() {
    export SAMBA_SCONFIG_SOURCE_ONLY=1
    export SAMBA_APPCORE_KVSTATE="${BATS_TEST_DIRNAME}/../../appliance-core/lib/kvstate.sh"
    export SAMBA_SYSVOL_SYNC_CONF="${BATS_TEST_TMPDIR}/sysvol-sync.conf"
    export SAMBA_SYSVOL_SYNC_CRON="${BATS_TEST_TMPDIR}/cron.d/sysvol-sync"
    export SAMBA_SYSVOL_SYNC_SERVICE_FILE="${BATS_TEST_TMPDIR}/units/samba-sysvol-sync.service"
    export SAMBA_SYSVOL_SYNC_TIMER_FILE="${BATS_TEST_TMPDIR}/units/samba-sysvol-sync.timer"
    export CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
    : > "$CALL_LOG"
    source "${BATS_TEST_DIRNAME}/../samba-sconfig.sh"
}

systemctl() { printf 'systemctl %s\n' "$*" >> "$CALL_LOG"; }

legacy_cron() {
    mkdir -p "$(dirname "$SAMBA_SYSVOL_SYNC_CRON")"
    printf '*/15 * * * * root /usr/local/sbin/sysvol-sync\n' > "$SAMBA_SYSVOL_SYNC_CRON"
}

@test "the timer install writes both units, enables the timer and drops the cron file" {
    legacy_cron
    run _install_sysvol_sync_timer 7
    [ "$status" -eq 0 ]
    grep -qx 'ExecStart=/usr/local/sbin/sysvol-sync' "$SAMBA_SYSVOL_SYNC_SERVICE_FILE"
    grep -qx 'OnUnitActiveSec=7min' "$SAMBA_SYSVOL_SYNC_TIMER_FILE"
    grep -qx 'Unit=samba-sysvol-sync.service' "$SAMBA_SYSVOL_SYNC_TIMER_FILE"
    [ ! -e "$SAMBA_SYSVOL_SYNC_CRON" ]
    grep -qx 'systemctl daemon-reload' "$CALL_LOG"
    grep -qx 'systemctl enable --now samba-sysvol-sync.timer' "$CALL_LOG"
}

@test "an interval outside 1-59 minutes is refused and nothing is written" {
    for bad in 0 60 abc ''; do
        run _install_sysvol_sync_timer "$bad"
        [ "$status" -ne 0 ]
    done
    [ ! -e "$SAMBA_SYSVOL_SYNC_TIMER_FILE" ]
    [ ! -s "$CALL_LOG" ]
}

@test "schedule on a never-configured DC uses the default and writes no settings" {
    run sysvol_sync_schedule
    [ "$status" -eq 0 ]
    grep -qx "OnUnitActiveSec=${SYSVOL_SYNC_DEFAULT_INTERVAL}min" "$SAMBA_SYSVOL_SYNC_TIMER_FILE"
    [ ! -e "$SAMBA_SYSVOL_SYNC_CONF" ]
}

@test "schedule keeps a stored interval and replaces a legacy cron schedule" {
    printf 'SYNC_INTERVAL="15"\nPREFERRED_DCS=""\nEXCLUDE_DCS=""\n' > "$SAMBA_SYSVOL_SYNC_CONF"
    legacy_cron
    run sysvol_sync_schedule
    [ "$status" -eq 0 ]
    grep -qx 'OnUnitActiveSec=15min' "$SAMBA_SYSVOL_SYNC_TIMER_FILE"
    [ ! -e "$SAMBA_SYSVOL_SYNC_CRON" ]
}

@test "schedule fails closed on a malformed settings file" {
    printf 'SYNC_INTERVAL="15"$(touch %s)\n' "${BATS_TEST_TMPDIR}/pwned" > "$SAMBA_SYSVOL_SYNC_CONF"
    run sysvol_sync_schedule
    [ "$status" -ne 0 ]
    [[ "$output" == *malformed* ]]
    [ ! -e "$SAMBA_SYSVOL_SYNC_TIMER_FILE" ]
    [ ! -e "${BATS_TEST_TMPDIR}/pwned" ]
}

@test "saving settings checks the interval and host lists before writing" {
    run _sysvol_sync_save 61 "" ""
    [ "$status" -eq 1 ]
    run _sysvol_sync_save 5 'dc1.lab.example;reboot' ""
    [ "$status" -eq 1 ]
    [ ! -e "$SAMBA_SYSVOL_SYNC_CONF" ]
    run _sysvol_sync_save 5 'dc1.lab.example dc2.lab.example' 'old.lab.example'
    [ "$status" -eq 0 ]
    local SYNC_INTERVAL PREFERRED_DCS EXCLUDE_DCS
    appcore_kv_load "$SAMBA_SYSVOL_SYNC_CONF" "${SYSVOL_SYNC_KEYS[@]}"
    [ "$SYNC_INTERVAL" = 5 ]
    [ "$PREFERRED_DCS" = 'dc1.lab.example dc2.lab.example' ]
    [ "$EXCLUDE_DCS" = 'old.lab.example' ]
}

@test "join and provision schedule the puller, after the SYSVOL seed on joins" {
    local f="${BATS_TEST_DIRNAME}/../samba-sconfig.sh" seed sched
    # Every seed_sysvol call is followed, before the outcome report, by a schedule.
    while IFS=: read -r seed _; do
        sched=$(awk -v s="$seed" 'NR > s && /sysvol_sync_schedule/ { print NR; exit }' "$f")
        [ -n "$sched" ] && [ $((sched - seed)) -le 4 ]
    done < <(grep -n '^ *seed_sysvol "\$dc_ip"' "$f")
    [ "$(grep -c 'sysvol_sync_schedule' "$f")" -ge 6 ]
}

#!/usr/bin/env bats

setup() {
    export SAMBA_SCONFIG_SOURCE_ONLY=1
    export SAMBA_SMB_CONF="${BATS_TEST_TMPDIR}/smb.conf"
    export SAMBA_SYSVOL_ACL_RESET_SERVICE="samba-sysvol-acl-reset.service"
    export SAMBA_SYSVOL_ACL_RESET_UNIT_FILE="${BATS_TEST_TMPDIR}/samba-sysvol-acl-reset.service"
    export SAMBA_SYSVOL_ACL_RESET_LOG="${BATS_TEST_TMPDIR}/sysvol-acl-reset.log"
    export SAMBA_SYSVOL_ACL_RESET_HEARTBEAT=0
    export SAMBA_SYSVOL_ACL_RESET_POLL=0.01
    export CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
    export MOCK_SYSTEMCTL_START_RC=0
    export MOCK_SYSTEMCTL_RUN_STEPS=3
    export MOCK_SYSTEMCTL_RUN_COUNT="${BATS_TEST_TMPDIR}/systemctl-run-count"
    export MOCK_ACTIVE_STATE=inactive
    export MOCK_SUB_STATE=dead
    export MOCK_RESULT=success
    export MOCK_EXEC_STATUS=0
    : > "$SAMBA_SMB_CONF"

    source "${BATS_TEST_DIRNAME}/../samba-sconfig.sh"
}

teardown() {
    unset SAMBA_SCONFIG_SOURCE_ONLY SAMBA_SMB_CONF SAMBA_SYSVOL_ACL_RESET_SERVICE \
          SAMBA_SYSVOL_ACL_RESET_UNIT_FILE SAMBA_SYSVOL_ACL_RESET_LOG \
          SAMBA_SYSVOL_ACL_RESET_HEARTBEAT SAMBA_SYSVOL_ACL_RESET_POLL \
          CALL_LOG MOCK_SYSTEMCTL_START_RC MOCK_SYSTEMCTL_RUN_STEPS \
          MOCK_SYSTEMCTL_RUN_COUNT \
          MOCK_ACTIVE_STATE MOCK_SUB_STATE MOCK_RESULT MOCK_EXEC_STATUS
}

systemctl() {
    printf 'systemctl %s\n' "$*" >> "$CALL_LOG"
    case "$1" in
        start)
            if [[ "$MOCK_SYSTEMCTL_START_RC" == "0" ]]; then
                printf '%s\n' 0 > "$MOCK_SYSTEMCTL_RUN_COUNT"
            fi
            return "$MOCK_SYSTEMCTL_START_RC"
            ;;
        list-jobs)
            if [[ -f "$MOCK_SYSTEMCTL_RUN_COUNT" ]] \
               && (( $(cat "$MOCK_SYSTEMCTL_RUN_COUNT") < MOCK_SYSTEMCTL_RUN_STEPS )); then
                printf '%s\n' '1 samba-sysvol-acl-reset.service start running'
            fi
            ;;
        show)
            case "$*" in
                *--property=ActiveState*)
                    if [[ -f "$MOCK_SYSTEMCTL_RUN_COUNT" ]]; then
                        local count
                        count=$(cat "$MOCK_SYSTEMCTL_RUN_COUNT")
                        if (( count < MOCK_SYSTEMCTL_RUN_STEPS )); then
                            printf '%s\n' activating
                            printf '%s\n' "$((count + 1))" > "$MOCK_SYSTEMCTL_RUN_COUNT"
                        else
                            printf '%s\n' inactive
                        fi
                    else
                        printf '%s\n' "$MOCK_ACTIVE_STATE"
                    fi
                    ;;
                *--property=SubState*) printf '%s\n' "$MOCK_SUB_STATE" ;;
                *--property=Result*) printf '%s\n' "$MOCK_RESULT" ;;
                *--property=ExecMainStatus*) printf '%s\n' "$MOCK_EXEC_STATUS" ;;
            esac
            ;;
    esac
}

ensure_idmap_config() {
    printf '%s\n' ensure-idmap >> "$CALL_LOG"
}

samba-tool() {
    printf 'samba-tool %s\n' "$*" >> "$CALL_LOG"
    printf '%s\n' 'reset detail from samba-tool'
    return "${MOCK_SAMBA_TOOL_RC:-0}"
}

@test "ACL reset unit is durable and invokes the internal worker" {
    run _install_sysvol_acl_reset_unit

    [ "$status" -eq 0 ]
    grep -Fq 'Type=oneshot' "$SAMBA_SYSVOL_ACL_RESET_UNIT_FILE"
    grep -Fq 'ExecStart=/usr/bin/flock --exclusive /run/sysvol-sync.lock /usr/local/sbin/samba-sconfig sysvol-acl-worker' "$SAMBA_SYSVOL_ACL_RESET_UNIT_FILE"
    grep -Fq 'TimeoutStartSec=2h' "$SAMBA_SYSVOL_ACL_RESET_UNIT_FILE"
    grep -Fq 'systemctl daemon-reload' "$CALL_LOG"
}

@test "image preparation installs the unit and periodic sync reuses it" {
    local prepare="${BATS_TEST_DIRNAME}/../prepare-image.sh"

    grep -Fq 'samba-sconfig sysvol-acl-install' "$prepare"
    grep -Fq 'systemctl start samba-sysvol-acl-reset.service' "$prepare"
    grep -Fq 'systemctl is-active --quiet samba-sysvol-acl-reset.service' "$prepare"
    grep -Fq 'flock -u 200' "$prepare"
}

@test "ACL reset worker records full output and completion duration" {
    run cli_sysvol_acl_worker

    [ "$status" -eq 0 ]
    [[ "$output" == *"SYSVOL NTACL reset started"* ]]
    [[ "$output" == *"reset detail from samba-tool"* ]]
    [[ "$output" == *"SYSVOL NTACL reset completed"* ]]
    grep -Fq 'reset detail from samba-tool' "$SAMBA_SYSVOL_ACL_RESET_LOG"
    grep -Fq 'SYSVOL NTACL reset completed' "$SAMBA_SYSVOL_ACL_RESET_LOG"
}

@test "ACL reset worker preserves samba-tool failure" {
    export MOCK_SAMBA_TOOL_RC=7

    run cli_sysvol_acl_worker

    [ "$status" -eq 7 ]
    [[ "$output" == *"SYSVOL NTACL reset FAILED (rc=7"* ]]
    grep -Fq 'SYSVOL NTACL reset FAILED (rc=7' "$SAMBA_SYSVOL_ACL_RESET_LOG"
}

@test "ACL reset monitor emits heartbeats while systemd owns the work" {
    run run_sysvol_acl_reset

    [ "$status" -eq 0 ]
    [[ "$output" == *"started as samba-sysvol-acl-reset.service"* ]]
    [[ "$output" == *"continues if this SSH session disconnects"* ]]
    [[ "$output" == *"still running"* ]]
    [[ "$output" == *"completed in"* ]]
    grep -Fq 'systemctl start --no-block samba-sysvol-acl-reset.service' "$CALL_LOG"
}

@test "ACL reset monitor returns failure instead of swallowing it" {
    export MOCK_RESULT=exit-code
    export MOCK_EXEC_STATUS=7
    printf '%s\n' 'worker failed detail' > "$SAMBA_SYSVOL_ACL_RESET_LOG"

    run run_sysvol_acl_reset

    [ "$status" -ne 0 ]
    [[ "$output" == *"ACL reset service failed"* ]]
    [[ "$output" == *"worker failed detail"* ]]
}

@test "ACL reset status is useful from a replacement SSH session" {
    export MOCK_ACTIVE_STATE=activating
    export MOCK_SUB_STATE=start
    export MOCK_RESULT=success
    printf '%s\n' '2026-08-06 10:00:00 SYSVOL NTACL reset started' > "$SAMBA_SYSVOL_ACL_RESET_LOG"

    run cli_sysvol_acl_status

    [ "$status" -eq 0 ]
    [[ "$output" == *"State: activating (start)"* ]]
    [[ "$output" == *"SYSVOL NTACL reset started"* ]]
    [[ "$output" == *"Log: $SAMBA_SYSVOL_ACL_RESET_LOG"* ]]
}

@test "join outcome is partial when SYSVOL ACL reset fails" {
    run _cli_report_join_outcome 2016 2 0

    [ "$status" -eq 2 ]
    [[ "$output" == *"JOINED, BUT SYSVOL ACL RESET FAILED"* ]]
    [[ "$output" == *"samba-sconfig sysvol-acl-status"* ]]
}

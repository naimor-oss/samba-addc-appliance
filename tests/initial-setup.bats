#!/usr/bin/env bats

setup() {
    REPO_DIR="${BATS_TEST_DIRNAME}/.."
    INITIAL="${BATS_TMPDIR}/samba-init"
    RESPONSES="${BATS_TMPDIR}/whiptail-responses"
    awk '
        /^cat > \/usr\/local\/sbin\/samba-init <<'\''INITEOF'\''/ {copy=1; next}
        /^INITEOF$/ {copy=0}
        copy
    ' "${REPO_DIR}/prepare-image.sh" > "$INITIAL"
    export SAMBA_INIT_SOURCE_ONLY=1
    # shellcheck disable=SC1090
    source "$INITIAL"
}

teardown() {
    unset SAMBA_INIT_SOURCE_ONLY
}

whiptail() {
    case " $* " in
        *" --inputbox "*)
            [[ -s "$RESPONSES" ]] || return 1
            local response
            response=$(head -n 1 "$RESPONSES")
            sed -i.bak '1d' "$RESPONSES"
            rm -f "${RESPONSES}.bak"
            printf '%s' "$response" >&2
            ;;
        *) return 0 ;;
    esac
}

@test "manual Ed25519 entry reconstructs four separately entered chunks" {
    key_file="${BATS_TEST_TMPDIR}/id_ed25519"
    ssh-keygen -q -t ed25519 -N "" -C "initial-setup-test" -f "$key_file"
    body=$(awk '{print $2}' "${key_file}.pub")
    [ "${#body}" -eq 68 ]
    {
        printf '%s\n' "${body:0:17}"
        printf '%s\n' "${body:17:17}"
        printf '%s\n' "${body:34:17}"
        printf '%s\n' "${body:51:17}"
    } > "$RESPONSES"

    run read_typed_ed25519_key

    [ "$status" -eq 0 ]
    [ "$output" = "ssh-ed25519 ${body}" ]
    [ ! -s "$RESPONSES" ]
}

@test "generated initial setup exposes source-only mode for behavioral tests" {
    grep -q 'SAMBA_INIT_SOURCE_ONLY' "$INITIAL"
}

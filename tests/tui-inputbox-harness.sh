#!/usr/bin/env bash
# Render and drive samba-init's real whiptail SSH-key input boxes in a PTY.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PREPARE="${REPO_DIR}/prepare-image.sh"
for command_name in awk grep ssh-keygen tmux whiptail; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "missing required command: $command_name" >&2
        exit 2
    }
done

work_dir=$(mktemp -d)
artifact_dir="${TUI_ARTIFACT_DIR:-${work_dir}/screens}"
mkdir -p "$artifact_dir"
socket="samba-tui-$$"

cleanup() {
    local rc=$?
    tmux -L "$socket" kill-server >/dev/null 2>&1 || true
    if [[ $rc -ne 0 ]]; then
        if [[ "$artifact_dir" != "$work_dir"* ]]; then
            rm -rf "${artifact_dir}/debug-work"
            cp -R "$work_dir" "${artifact_dir}/debug-work"
        fi
        echo "TUI screen captures retained at: $artifact_dir" >&2
    fi
    if [[ -z "${TUI_ARTIFACT_DIR:-}" && $rc -eq 0 ]]; then
        rm -rf "$work_dir"
    elif [[ "$artifact_dir" != "$work_dir"* ]]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

initial="${work_dir}/samba-init"
awk '
    /^cat > \/usr\/local\/sbin\/samba-init <<'\''INITEOF'\''/ {copy=1; next}
    /^INITEOF$/ {copy=0}
    copy
' "$PREPARE" > "$initial"
grep -q 'SAMBA_INIT_SOURCE_ONLY' "$initial"

key_file="${work_dir}/id_ed25519"
ssh-keygen -q -t ed25519 -N "" -C "tui-inputbox-harness" -f "$key_file"
public_key=$(cat "${key_file}.pub")
key_body=$(awk '{print $2}' "${key_file}.pub")
[[ ${#key_body} -eq 68 ]]

capture_screen() {
    local session="$1" output="$2"
    tmux -L "$socket" capture-pane -p -t "$session" > "$output"
}

wait_for_screen() {
    local session="$1" expected="$2" output="$3"
    local attempt
    for attempt in $(seq 1 60); do
        if tmux -L "$socket" has-session -t "$session" 2>/dev/null; then
            capture_screen "$session" "$output"
            grep -Fq "$expected" "$output" && return 0
        fi
        sleep 0.1
    done
    echo "did not render expected text: $expected" >&2
    [[ -f "$output" ]] && cat "$output" >&2
    return 1
}

wait_for_result() {
    local session="$1" result="$2"
    local attempt
    for attempt in $(seq 1 60); do
        [[ -s "$result" ]] && return 0
        if tmux -L "$socket" has-session -t "$session" 2>/dev/null; then
            capture_screen "$session" "${artifact_dir}/${session}-final.txt"
        else
            break
        fi
        sleep 0.1
    done
    echo "TUI function did not return a value" >&2
    return 1
}

start_function() {
    local session="$1" function_name="$2" result="$3"
    local runner="${work_dir}/run-${session}.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -u'
        echo 'export SAMBA_INIT_SOURCE_ONLY=1'
        printf 'source %q\n' "$initial"
        printf '%s > %q\n' "$function_name" "$result"
    } > "$runner"
    chmod +x "$runner"
    tmux -L "$socket" new-session -d -x 80 -y 24 -s "$session" "$runner"
}

send_literal() {
    local session="$1" value="$2"
    tmux -L "$socket" send-keys -t "$session" -l "$value"
    tmux -L "$socket" send-keys -t "$session" Enter
}

typed_session="typed-key"
typed_result="${work_dir}/typed-result"
start_function "$typed_session" read_typed_ed25519_key "$typed_result"
for part in 1 2 3 4; do
    start=$(( (part - 1) * 17 ))
    chunk="${key_body:start:17}"
    screen="${artifact_dir}/typed-part-${part}.txt"
    wait_for_screen "$typed_session" "Ed25519 part ${part}/4" "$screen"
    grep -Fq "Ruler: 12345678901234567" "$screen"
    send_literal "$typed_session" "$chunk"
done
wait_for_result "$typed_session" "$typed_result"
[[ "$(cat "$typed_result")" == "ssh-ed25519 ${key_body}" ]]

paste_session="pasted-key"
paste_result="${work_dir}/paste-result"
start_function "$paste_session" read_pasted_ssh_key "$paste_result"
paste_screen="${artifact_dir}/paste-key.txt"
wait_for_screen "$paste_session" "Paste SSH public key" "$paste_screen"
grep -Fq "entry field" "$paste_screen"
send_literal "$paste_session" "$public_key"
wait_for_result "$paste_session" "$paste_result"
[[ "$(cat "$paste_result")" == "$public_key" ]]

echo "PASS: real whiptail paste and four-part Ed25519 input boxes"
echo "Rendered screens: $artifact_dir"

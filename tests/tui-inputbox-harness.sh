#!/usr/bin/env bash
# Render and drive samba-init's real SSH-key dialogs in a PTY.

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PREPARE="${REPO_DIR}/prepare-image.sh"
for command_name in awk dialog grep ssh-keygen tmux whiptail; do
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

assert_ruler_alignment() {
    local session="$1" screen="$2"
    local ruler_position cursor_position ruler_row ruler_col cursor_row cursor_col
    ruler_position=$(awk '
        index($0, "12345678901234567") {
            print NR, index($0, "12345678901234567")
            exit
        }
    ' "$screen")
    cursor_position=$(tmux -L "$socket" display-message -p -t "$session" \
        '#{cursor_y} #{cursor_x}')
    read -r ruler_row ruler_col <<< "$ruler_position"
    read -r cursor_row cursor_col <<< "$cursor_position"
    cursor_row=$((cursor_row + 1))
    cursor_col=$((cursor_col + 1))
    if [[ -z "${ruler_row:-}" ||
          $cursor_row -ne $((ruler_row + 1)) ||
          $cursor_col -ne $ruler_col ]]; then
        echo "ruler is not directly aligned above the input field" >&2
        echo "ruler=${ruler_row:-missing}:${ruler_col:-missing} cursor=${cursor_row}:${cursor_col}" >&2
        cat "$screen" >&2
        return 1
    fi
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
initial_screen="${artifact_dir}/typed-part-1-initial.txt"
wait_for_screen "$typed_session" "Ed25519 part 1/4" "$initial_screen"
assert_ruler_alignment "$typed_session" "$initial_screen"
send_literal "$typed_session" "${key_body:0:17}X"
retry_screen="${artifact_dir}/typed-part-1-retry.txt"
wait_for_screen "$typed_session" "Error: enter exactly 17 characters" "$retry_screen"
grep -Fq "Ed25519 part 1/4" "$retry_screen"
assert_ruler_alignment "$typed_session" "$retry_screen"
send_literal "$typed_session" "${key_body:0:16}!"
character_retry_screen="${artifact_dir}/typed-part-1-character-retry.txt"
wait_for_screen "$typed_session" "Error: use only A-Z, a-z, 0-9, +, or /" \
    "$character_retry_screen"
grep -Fq "Ed25519 part 1/4" "$character_retry_screen"
assert_ruler_alignment "$typed_session" "$character_retry_screen"

for part in 1 2 3 4; do
    start=$(( (part - 1) * 17 ))
    chunk="${key_body:start:17}"
    screen="${artifact_dir}/typed-part-${part}.txt"
    wait_for_screen "$typed_session" "Ed25519 part ${part}/4" "$screen"
    assert_ruler_alignment "$typed_session" "$screen"
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

echo "PASS: real paste and four-part Ed25519 console dialogs"
echo "Rendered screens: $artifact_dir"

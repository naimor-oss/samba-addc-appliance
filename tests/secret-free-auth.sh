#!/usr/bin/env bash
# Passwords must never reach a process argument vector (code-review session
# plan 01). Real-Samba behaviour (provision, join-style network auth,
# setpassword, smbclient) was verified in Debian 13 with a /proc/*/cmdline
# sampler; this test keeps the mechanism and the call sites honest in CI.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCONFIG="$ROOT/samba-sconfig.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/secret-free-auth.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
SECRET='Zq9!marker $(id) `x` "q" back\slash'

# 1. No call site may pass a password as an argument.
leaks=$(grep -nE -- '--(adminpass|password|newpassword)=|-U[^ ]*%\$' "$SCONFIG" | grep -v '^\s*[0-9]*:\s*#' || true)
[[ -z "$leaks" ]] || fail "password-bearing argument in samba-sconfig.sh:"$'\n'"$leaks"

# 2. The in-process samba-tool wrapper: a fake samba.netcmd.main records the
#    arguments it receives and the process's real /proc/self/cmdline.
mkdir -p "$T/py/samba/netcmd"
: > "$T/py/samba/__init__.py"; : > "$T/py/samba/netcmd/__init__.py"
cat > "$T/py/samba/netcmd/main.py" <<'PY'
import json, os
def samba_tool(*args):
    with open("/proc/self/cmdline", "rb") as f:
        cmdline = f.read().replace(b"\0", b" ").decode()
    with open(os.environ["FAKE_OUT"], "w") as f:
        json.dump({"args": list(args), "cmdline": cmdline}, f)
    return 0
PY
eval "$(sed -n '/^readonly SAMBA_TOOL_STDIN_PY=/,/^samba_tool_secret() {/{/^samba_tool_secret() {/d;p}' "$SCONFIG")"
eval "$(sed -n '/^samba_tool_secret() {/,/^}$/p; /^run_with_auth_file() {/,/^}$/p' "$SCONFIG")"

FAKE_OUT="$T/out.json" PYTHONPATH="$T/py" \
    samba_tool_secret --password "$SECRET" domain join LAB.TEST DC -U 'LAB\admin'
python3 - "$T/out.json" "$SECRET" <<'PY' || fail "samba_tool_secret did not pass the secret correctly"
import json, sys
d = json.load(open(sys.argv[1])); secret = sys.argv[2]
assert d["args"] == ["domain", "join", "LAB.TEST", "DC", "-U", "LAB\\admin", "--password=" + secret], d["args"]
assert secret not in d["cmdline"] and "Zq9!marker" not in d["cmdline"], d["cmdline"]
PY

# 3. The authentication file: fake smbclient records argv and file content.
mkdir -p "$T/bin" "$T/run"
cat > "$T/bin/smbclient" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_ARGV"
for ((i = 1; i <= $#; i++)); do
    if [[ "${!i}" == -A ]]; then j=$((i + 1)); cp "${!j}" "$FAKE_AUTH"; stat -c %a "${!j}" > "$FAKE_MODE"; fi
done
SH
chmod +x "$T/bin/smbclient"
PATH="$T/bin:$PATH" SCONFIG_AUTH_DIR="$T/run" FAKE_ARGV="$T/argv" FAKE_AUTH="$T/auth" FAKE_MODE="$T/mode" \
    run_with_auth_file LAB administrator "$SECRET" smbclient //dc/sysvol -c ls
! grep -qF 'Zq9!marker' "$T/argv" || fail "secret reached smbclient argv"
grep -qxF "password = $SECRET" "$T/auth" || fail "auth file password line wrong"
grep -qxF 'domain = LAB' "$T/auth" || fail "auth file domain missing"
[[ "$(cat "$T/mode")" == 600 ]] || fail "auth file mode is $(cat "$T/mode"), want 600"
[[ -z "$(ls -A "$T/run")" ]] || fail "auth directory not removed"

# Removed even when the command fails, and the command's status is kept.
cat > "$T/bin/smbclient" <<'SH'
#!/usr/bin/env bash
exit 7
SH
rc=0; PATH="$T/bin:$PATH" SCONFIG_AUTH_DIR="$T/run" run_with_auth_file LAB a "$SECRET" smbclient x || rc=$?
[[ $rc -eq 7 ]] || fail "failing command status not propagated (rc=$rc)"
[[ -z "$(ls -A "$T/run")" ]] || fail "auth directory left after failure"

# Blank-edged secrets would be trimmed by Samba's parser: refuse them.
rc=0; SCONFIG_AUTH_DIR="$T/run" run_with_auth_file LAB a ' padded' true 2>/dev/null || rc=$?
[[ $rc -eq 2 ]] || fail "secret with leading space not refused"

echo "secret-free auth tests passed"

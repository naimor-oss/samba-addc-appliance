#!/usr/bin/env bash
# Build the Samba AD DC update bundle for the version in ../VERSION, using the
# appliance-core update framework (../appliance-core/update/build-bundle.sh).
#
#   updates/build-bundle.sh [--out DIR]
#
# The payload is exactly what a fresh image would install: the repo's
# scripts, plus the generated scripts lifted from prepare-image.sh, so a
# bundle and an image built from the same commit never disagree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPCORE="${APPCORE_REPO:-$ROOT/../appliance-core}"
out="$ROOT/dist"
[[ "${1:-}" == --out ]] && out="$2"
[[ -x "$APPCORE/update/build-bundle.sh" ]] \
    || { echo "appliance-core with update/ not found at $APPCORE" >&2; exit 2; }

version=$(head -1 "$ROOT/VERSION")
accepts=$(head -1 "$ROOT/updates/bundle/ACCEPTS")
stage=$(mktemp -d "${TMPDIR:-/tmp}/samba-addc-bundle.XXXXXX")
trap 'rm -rf "$stage"' EXIT
install -d "$stage/sbin" "$stage/motd"

install -m 0755 "$ROOT/samba-sconfig.sh" "$stage/sbin/samba-sconfig"
install -m 0755 "$ROOT/samba-addc-update" "$stage/sbin/samba-addc-update"

# Print the body of `cat > PATH <<'TERM'` ... TERM from prepare-image.sh.
lift() {
    awk -v path="$1" '
        !inside && index($0, "cat > " path " <<") == 1 {
            term = $0; sub(/^.*<< *'"'"'?/, "", term); sub(/'"'"'.*$/, "", term)
            inside = 1; found = 1; next
        }
        inside && $0 == term { exit }
        inside { print }
        END { if (!found) exit 1 }
    ' "$ROOT/prepare-image.sh"
}
lift /usr/local/sbin/sysvol-sync > "$stage/sbin/sysvol-sync"
lift /usr/local/sbin/samba-dfs-parse-targets > "$stage/sbin/samba-dfs-parse-targets"
lift /usr/local/sbin/samba-firstboot > "$stage/sbin/samba-firstboot"
lift /usr/local/sbin/samba-init > "$stage/sbin/samba-init"
lift /etc/update-motd.d/15-samba-net-status > "$stage/motd/15-samba-net-status"
chmod 0755 "$stage"/sbin/* "$stage"/motd/*
for f in "$stage"/sbin/* "$stage"/motd/*; do
    [[ -s "$f" ]] || { echo "lifted file is empty: $f" >&2; exit 2; }
    head -1 "$f" | grep -q '^#!' || { echo "lifted file has no shebang: $f" >&2; exit 2; }
done
bash -n "$stage"/sbin/sysvol-sync "$stage"/sbin/samba-firstboot "$stage"/sbin/samba-init
git -C "$APPCORE" rev-parse HEAD > "$stage/appcore-commit" 2>/dev/null || echo unknown > "$stage/appcore-commit"

migrations="$ROOT/updates/bundle/migrations"
args=(--appliance samba-addc --version "$version" --accepts "$accepts"
      --hooks "$ROOT/updates/bundle/hooks.sh" --payload "$stage" --out "$out"
      --commit "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)")
[[ -d "$migrations" ]] && args+=(--migrations "$migrations")
"$APPCORE/update/build-bundle.sh" "${args[@]}"

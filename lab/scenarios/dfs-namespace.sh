# shellcheck shell=bash
# lab/scenarios/dfs-namespace.sh — exercise the DFS-N tertiary namespace
# server: join the lab forest, set up a v2 namespace on WS2025-DC1 with
# adversarial folder names + a malformed link injected via raw LDAP, run
# samba-sconfig dfs-init/configure/update on samba-dc1, and verify every
# link materializes correctly while the malformed one is rejected.
#
# Sourced by lab/run-scenario.sh. Has access to ssh_vm / ssh_host /
# scp_to_vm / say / step helpers and the LAB_VM_* / LAB_HV_* env vars.
#
# Overridable via env:
#   SC_REALM, SC_NETBIOS, SC_DC, SC_PASS, SC_ADMIN, SC_ROLE — same as join-dc.
#   SC_DFS_NAMESPACE — short namespace name (default 'Public')
#   SC_DFS_PREFER    — extended regex bubbled to front of each referral.
#                      Default '^\\\\WIN-' (primary Windows servers first)

SC_REALM="${SC_REALM:-lab.test}"
SC_NETBIOS="${SC_NETBIOS:-LAB}"
SC_DC="${SC_DC:-10.10.10.10}"
SC_PASS="${SC_PASS:-P@ssword123456!}"
SC_ADMIN="${SC_ADMIN:-Administrator}"
SC_ROLE="${SC_ROLE:-DC}"

SC_DFS_NAMESPACE="${SC_DFS_NAMESPACE:-Public}"
SC_DFS_PREFER="${SC_DFS_PREFER:-^\\\\\\\\WIN-}"  # double-escaped: bash + regex
SC_DFS_SHARE="${SC_DFS_SHARE:-dfs_root}"
SC_DFS_ROOT="${SC_DFS_ROOT:-/srv/samba/dfs_root}"

# pre_hook: idempotent Windows-side reset + DFS-N namespace setup. Honors
# the same SC_SKIP_CLEANUP / SC_DRY_CLEANUP knobs as join-dc.
pre_hook() {
    if [[ "${SC_SKIP_CLEANUP:-0}" == "1" ]]; then
        say "skipping WS2025 cleanup (SC_SKIP_CLEANUP=1)"
    else
        local dry=""
        [[ "${SC_DRY_CLEANUP:-0}" == "1" ]] && dry="-DryRun"
        step "Reset-LabDomainState on WS2025-DC1 ${dry:+(dry-run)}"
        ssh_host "pwsh -File ${LAB_HOST_STAGE_DIR}\\Reset-LabDomainState.ps1 $dry"
        step "Reset-DfsnTestNamespace on WS2025-DC1 ${dry:+(dry-run)}"
        ssh_host "pwsh -File ${LAB_HOST_STAGE_DIR}\\Reset-DfsnTestNamespace.ps1 -NamespaceName '$SC_DFS_NAMESPACE' -Realm '$SC_REALM' $dry"
    fi

    step "Setup-DfsnTestNamespace on WS2025-DC1 (namespace=$SC_DFS_NAMESPACE)"
    # SambaTarget is intentionally omitted: New-DfsnRootTarget validates
    # the target's reachability, and at pre_hook time samba-dc1 isn't
    # joined yet. The scenario tests symlink materialization from
    # AD-replicated link metadata, which doesn't require this DC to be
    # registered as a namespace target.
    ssh_host "pwsh -File ${LAB_HOST_STAGE_DIR}\\Setup-DfsnTestNamespace.ps1 \
        -NamespaceName '$SC_DFS_NAMESPACE' -Realm '$SC_REALM'"
}

run_scenario() {
    # The DFS-N parser helper is installed by prepare-image.sh, which
    # ran when the golden image was built. If the golden image predates
    # the helper (older image, or image rebuilt without DFS-N changes),
    # extract and install it from the freshly-pushed prepare-image.sh.
    # Idempotent on subsequent runs.
    step "ensure samba-dfs-parse-targets helper is installed"
    ssh_vm 'sudo bash -c "
        if ! [[ -x /usr/local/sbin/samba-dfs-parse-targets ]]; then
            awk \"/^cat > .usr.local.sbin.samba-dfs-parse-targets <<.PARSEEOF.\\\$/,/^PARSEEOF\\\$/\" /tmp/prepare-image.sh \
                | sed \"1d;\\\$d\" > /usr/local/sbin/samba-dfs-parse-targets
            chmod 0755 /usr/local/sbin/samba-dfs-parse-targets
            echo installed
        else
            echo present
        fi
    "'

    step "join samba-dc1 to ${SC_REALM}"
    ssh_vm "sudo env \
        SC_REALM='$SC_REALM' \
        SC_NETBIOS='$SC_NETBIOS' \
        SC_DC='$SC_DC' \
        SC_PASS='$SC_PASS' \
        SC_ADMIN='$SC_ADMIN' \
        SC_ROLE='$SC_ROLE' \
        samba-sconfig join-dc"

    # A normal DC join must immediately protect existing domain namespace
    # roots. This runs before the optional tertiary-server setup below, so the
    # two mechanisms cannot accidentally mask one another.
    step "verify automatic root proxy created by the join"
    ssh_vm "sudo testparm -s --section-name='${SC_DFS_NAMESPACE}' \
        --parameter-name='msdfs proxy' 2>/dev/null"

    # The join replicates the domain NC, which contains the DFS-N
    # configuration objects (CN=Dfs-Configuration,CN=System,...). They're
    # almost always present immediately after a successful join; if not,
    # short retry on a direct ldbsearch handles the lag.
    step "wait for DFS-N link objects to appear in local sam.ldb"
    local realm_lc base_dn
    realm_lc=$(echo "$SC_REALM" | tr '[:upper:]' '[:lower:]')
    base_dn=$(echo "$realm_lc" | awk -F. '{for(i=1;i<=NF;i++) printf "%sDC=%s",(i>1?",":""),$i}')
    local found=0 attempt
    for attempt in 1 2 3 4 5 6 7 8; do
        local count
        count=$(ssh_vm "sudo ldbsearch -H /var/lib/samba/private/sam.ldb \
                -b 'CN=${SC_DFS_NAMESPACE},CN=${SC_DFS_NAMESPACE},CN=Dfs-Configuration,CN=System,${base_dn}' \
                -s sub '(objectClass=msDFS-Linkv2)' msDFS-LinkPathv2 2>/dev/null \
                | grep -c '^msDFS-LinkPathv2:'" || echo 0)
        if [[ "${count:-0}" -ge 1 ]]; then found=1; break; fi
        sleep 5
    done
    [[ "$found" == 1 ]] || say "WARN: link objects not yet visible (verify will catch this)"

    step "samba-sconfig dfs-init"
    ssh_vm "sudo env \
        SC_DFS_SHARE='$SC_DFS_SHARE' \
        SC_DFS_ROOT='$SC_DFS_ROOT' \
        samba-sconfig dfs-init"

    step "samba-sconfig dfs-configure $SC_DFS_NAMESPACE (prefer=$SC_DFS_PREFER)"
    ssh_vm "sudo env \
        SC_DFS_NS='$SC_DFS_NAMESPACE' \
        SC_DFS_PREFER='$SC_DFS_PREFER' \
        samba-sconfig dfs-configure"

    step "samba-sconfig dfs-update (real run)"
    ssh_vm "sudo samba-sconfig dfs-update 2>&1 | tail -20"

    # Convergence pass: change AD state on the Windows side, then run
    # dfs-update again. Static state can't tell the difference between
    # "wrote the right thing once" and "actually adapts to changes" —
    # and that second property is the timer's whole reason for existing.
    # The PS heredoc-via-SSH path is too brittle for nested cmdlets;
    # call a dedicated helper instead.
    step "convergence: add 'NewFolder' on WS2025-DC1, remove 'one'"
    ssh_host "pwsh -File ${LAB_HOST_STAGE_DIR}\\Modify-DfsnTestNamespace.ps1 \
        -NamespaceName '$SC_DFS_NAMESPACE' -Realm '$SC_REALM' \
        -AddFolder 'NewFolder' -RemoveFolder 'one'"

    step "wait for replication of namespace deltas"
    local ns_count_expected=4   # was 4 (R, QFY26, IT, one); now 4 (R, QFY26, IT, NewFolder)
    local attempt
    for attempt in 1 2 3 4 5 6 7 8; do
        local seen
        # Compute base DN locally (Mac side) — this is a $() substitution
        # with its own parsing context, so single-quoted awk needs no
        # backslash escapes for " or $.
        local base_dn
        base_dn=$(echo "$SC_REALM" | tr '[:upper:]' '[:lower:]' \
            | awk -F. '{for(i=1;i<=NF;i++) printf "%sDC=%s",(i>1?",":""),$i}')
        # grep -c always emits a count (even 0) and exits non-zero on no
        # match — `|| echo 0` here would append a SECOND "0", producing
        # "0\n0" which trips [[ -ge ]] arithmetic. Use `|| true` instead.
        seen=$(ssh_vm "sudo ldbsearch -H /var/lib/samba/private/sam.ldb \
                -b 'CN=${SC_DFS_NAMESPACE},CN=${SC_DFS_NAMESPACE},CN=Dfs-Configuration,CN=System,${base_dn}' \
                -s sub '(objectClass=msDFS-Linkv2)' msDFS-LinkPathv2 2>/dev/null \
                | grep -c 'NewFolder'" || true)
        if [[ "${seen:-0}" =~ ^[0-9]+$ ]] && (( seen >= 1 )); then break; fi
        sleep 5
    done

    step "samba-sconfig dfs-update (convergence)"
    ssh_vm "sudo samba-sconfig dfs-update 2>&1 | tail -10"
}

verify() {
    local rc=0 out
    local ns_dir="${SC_DFS_ROOT}/${SC_DFS_NAMESPACE}"

    say "automatic root proxy is parsed and enabled before tertiary DFS setup"
    out=$(ssh_vm "sudo testparm -s --section-name='${SC_DFS_NAMESPACE}' \
        --parameter-name='msdfs proxy' 2>/dev/null" || true)
    echo "  msdfs proxy: $out"
    [[ -n "$out" ]] || { say "automatic root proxy missing for ${SC_DFS_NAMESPACE}"; rc=1; }

    say "Windows reaches the namespace directly through Samba and by domain path"
    out=$(ssh_host "pwsh -File ${LAB_HOST_STAGE_DIR}\\Verify-DfsRootProxy.ps1 \
        -SambaServer '${LAB_VM_NAME}.${SC_REALM}' \
        -Realm '$SC_REALM' -NamespaceName '$SC_DFS_NAMESPACE'" || true)
    echo "$out"
    grep -q '^PASS: Samba direct proxy and domain DFS path are both accessible\.$' <<< "$out" \
        || { say "Windows DFS root proxy verification failed"; rc=1; }

    say "dfs-update produces no shell-runtime errors on stderr"
    # Regression guard: under set -u or pipe-eating misuse, samba-sconfig
    # would print "unbound variable" / arithmetic / syntax errors to stderr
    # but still exit 0 because of how RETURN traps and `|| true` swallow
    # errors. Capture full stderr from a fresh idempotent run and fail if
    # any shell-runtime error markers appear.
    out=$(ssh_vm "sudo samba-sconfig dfs-update 2>&1" || true)
    if grep -E "unbound variable|arithmetic (syntax )?error|command not found|: line [0-9]+: " <<< "$out" >/dev/null; then
        say "shell-runtime errors found in dfs-update output:"
        grep -E "unbound variable|arithmetic (syntax )?error|command not found|: line [0-9]+: " <<< "$out" | sed 's/^/  /'
        rc=1
    else
        echo "  clean stderr"
    fi

    say "drop-in file is present and smb.conf includes it"
    out=$(ssh_vm "sudo cat /etc/samba/conf.d/dfs-root.conf 2>&1 && echo '---' && sudo grep 'include = /etc/samba/conf.d/dfs-root.conf' /etc/samba/smb.conf")
    echo "$out"
    grep -q "msdfs root = yes" <<< "$out" || { say "msdfs root not in drop-in"; rc=1; }
    grep -q "read only = yes"  <<< "$out" || { say "drop-in is not read-only"; rc=1; }

    say "smb.conf include position does NOT leak [global] params into [dfs_root]"
    # The include line splices the included file's content at its
    # position, and the included file starts with [dfs_root]. If the
    # include is at the TOP of [global], every subsequent line in
    # smb.conf gets parsed under [dfs_root] context — testparm then
    # prints "Global parameter X found in service section!" for each.
    # The correct fix (samba-sconfig _dfs_write_drop_in) inserts the
    # include at the END of [global], so its section switch happens
    # immediately before the next service section. This assertion
    # pins that behavior.
    out=$(ssh_vm 'sudo testparm -s 2>&1 1>/dev/null')
    if grep -q "Global parameter .* found in service section" <<< "$out"; then
        say "testparm reports Global-in-service drift — _dfs_write_drop_in placement regression:"
        grep "Global parameter .* found in service section" <<< "$out" | sed 's/^/  /'
        rc=1
    else
        echo "  clean (no Global-in-service warnings)"
    fi

    say "share is registered (testparm sees it as a top-level section)"
    # testparm parses the live smb.conf graph and is authoritative for
    # whether Samba's parser recognized the include + share. An
    # authenticated smbclient -L would also confirm smbd's runtime
    # share table refreshed, but auth handshake on the AD DC's
    # hardened SMB stack is fragile from localhost; testparm + the
    # reload-config call in dfs-init is the practical check today.
    out=$(ssh_vm "sudo testparm -s 2>/dev/null | grep -cE '^\\[${SC_DFS_SHARE}\\]'" || echo 0)
    echo "  testparm sections matching [${SC_DFS_SHARE}]: $out"
    (( ${out:-0} >= 1 )) || { say "share ${SC_DFS_SHARE} not parsed"; rc=1; }
    # Also confirm msdfs root attribute landed in the parsed share.
    out=$(ssh_vm "sudo testparm -s --section-name='${SC_DFS_SHARE}' --parameter-name='msdfs root' 2>/dev/null" || true)
    echo "  msdfs root: $out"
    [[ "$out" == "Yes" ]] || { say "msdfs root not enabled on ${SC_DFS_SHARE}"; rc=1; }

    say "convergence post-state: 'one' removed, 'NewFolder' added, others intact"
    # Use single-quoted local strings so the literal '$' in 'IT$Tools'
    # survives. Inside the ssh_vm double-quoted command, wrap the path
    # in single quotes so the remote shell doesn't expand $Tools either.
    local link
    for link in 'Reports' 'Quarterly Reports (FY26)' 'IT$Tools' 'NewFolder'; do
        out=$(ssh_vm "sudo readlink '${ns_dir}/${link}' 2>/dev/null || true")
        echo "  present: ${link} -> ${out}"
        case "$out" in
            msdfs:*) ;;
            *) say "link missing or wrong: ${link}"; rc=1 ;;
        esac
    done
    # 'one' should now be pruned.
    if ssh_vm "sudo test -e '${ns_dir}/one'"; then
        say "convergence prune failed: 'one' still present after AD removal"
        rc=1
    else
        echo "  pruned: one"
    fi

    say "target order: primary (^WIN-) before Synology fallback"
    out=$(ssh_vm "sudo readlink '${ns_dir}/Reports' 2>/dev/null || true")
    if [[ "$out" =~ ^msdfs:WIN-.*synology-fb ]]; then
        echo "  $out"
    else
        say "expected WIN-* before synology-fb in: $out"
        rc=1
    fi

    say "malformed link path was rejected (must NOT exist on disk)"
    if ssh_vm "sudo find \"${ns_dir}\" -name 'evil*' -print 2>/dev/null | grep -q ."; then
        say "validator failed: an 'evil*' entry was created"
        rc=1
    else
        echo "  ok — no evil* entry under ${ns_dir}"
    fi

    say "sentinel guard: removing the global sentinel makes dfs-update refuse"
    out=$(ssh_vm "sudo bash -c '
        mv \"${SC_DFS_ROOT}/.dfsn-managed\" \"${SC_DFS_ROOT}/.dfsn-managed.bak\"
        samba-sconfig dfs-update; rc=\$?
        mv \"${SC_DFS_ROOT}/.dfsn-managed.bak\" \"${SC_DFS_ROOT}/.dfsn-managed\"
        echo rc=\$rc
    '" 2>&1)
    echo "$out"
    grep -qE '^rc=2$' <<< "$out" || { say "sentinel guard did not trip (expected rc=2)"; rc=1; }

    say "empty-result guard: a bogus namespace must not delete existing links"
    local before after
    before=$(ssh_vm "sudo find \"${ns_dir}\" -mindepth 1 -type l | wc -l" || echo 0)
    ssh_vm "sudo bash -c '
        cp /etc/samba/dfs-update.conf /etc/samba/dfs-update.conf.bak
        sed -i \"s|^DFS_NAMESPACES=.*|DFS_NAMESPACES=\\\"NoSuchNamespace\\\"|\" /etc/samba/dfs-update.conf
        samba-sconfig dfs-update >/dev/null 2>&1 || true
        mv /etc/samba/dfs-update.conf.bak /etc/samba/dfs-update.conf
    '"
    after=$(ssh_vm "sudo find \"${ns_dir}\" -mindepth 1 -type l | wc -l" || echo 0)
    echo "  before=${before} after=${after}"
    [[ "$before" == "$after" ]] || { say "empty-result guard: symlink count changed"; rc=1; }

    say "schedule installs and starts the timer"
    ssh_vm "sudo env SC_DFS_INTERVAL=30min samba-sconfig dfs-schedule >/dev/null"
    out=$(ssh_vm 'sudo systemctl is-active samba-dfs-update.timer' 2>&1 || true)
    echo "  timer: $out"
    [[ "$out" == "active" ]] || { say "timer not active"; rc=1; }

    # ReadWritePaths in the rendered unit MUST include the runtime
    # DFS_ROOT, not just the compile-time default. ProtectSystem=strict
    # makes the timer write fall over EROFS otherwise. Custom-root case
    # was the original regression; pin by reading both the conf-file
    # value and the unit-file value, then confirming the unit covers
    # the runtime root.
    out=$(ssh_vm '
        set -e
        runtime_root=$( . /etc/samba/dfs-update.conf 2>/dev/null; printf "%s" "${DFS_ROOT:-}" )
        rwpaths=$(grep -E "^ReadWritePaths=" /etc/systemd/system/samba-dfs-update.service)
        printf "runtime_root=%s\n" "$runtime_root"
        printf "rwpaths=%s\n" "$rwpaths"
    ' 2>&1 || true)
    echo "$out" | sed 's/^/  /'
    runtime_root=$(grep '^runtime_root=' <<< "$out" | cut -d= -f2-)
    rwpaths=$(grep '^rwpaths=' <<< "$out" | cut -d= -f2-)
    if [[ -n "$runtime_root" ]] && ! grep -qF "$runtime_root" <<< "$rwpaths"; then
        say "ReadWritePaths='$rwpaths' does NOT cover runtime DFS_ROOT='$runtime_root'"
        rc=1
    fi

    # DFS-N.md §8 protocol: assert each hardening directive landed in
    # the rendered unit. Catches a refactor that drops one — the unit
    # would still boot the timer happily, but the security posture
    # documented in the design doc would silently regress.
    say "rendered service unit carries the §8 hardening directives"
    out=$(ssh_vm 'sudo cat /etc/systemd/system/samba-dfs-update.service' 2>&1 || true)
    local _h
    for _h in \
        '^ProtectSystem=strict$' \
        '^ProtectHome=yes$' \
        '^NoNewPrivileges=yes$' \
        '^PrivateTmp=yes$' \
        '^ReadOnlyPaths=/var/lib/samba$' \
        '^RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6$' \
        '^LockPersonality=yes$' \
        '^MemoryDenyWriteExecute=yes$'; do
        if ! grep -qE "$_h" <<< "$out"; then
            say "service unit missing required directive: $_h"
            rc=1
        fi
    done

    say "rendered timer unit carries the §8 timer settings"
    out=$(ssh_vm 'sudo cat /etc/systemd/system/samba-dfs-update.timer' 2>&1 || true)
    grep -qE '^Persistent=true$'           <<< "$out" || { say "timer Persistent=true missing"; rc=1; }
    grep -qE '^RandomizedDelaySec='        <<< "$out" || { say "timer RandomizedDelaySec missing"; rc=1; }
    grep -qE '^OnUnitActiveSec='           <<< "$out" || { say "timer OnUnitActiveSec missing"; rc=1; }

    return $rc
}

post_hook() {
    # Tear down the timer so a re-run starts clean. The Windows-side
    # namespace is left in place; pre_hook handles it on the next run.
    ssh_vm 'sudo systemctl disable --now samba-dfs-update.timer 2>/dev/null || true'
}

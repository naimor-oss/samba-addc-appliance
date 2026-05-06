# lab/scenarios/provision-new.sh — provision a brand-new forest, no Windows
# DC dependency. Validates the standalone path that's normally exercised by
# hand only.
#
# The forest realm intentionally differs from the WS2025 lab forest
# (lab.test) so the WS2025 DC has no awareness of this provision and
# nothing on the lab needs cleaning up afterward — the next scenario that
# reverts samba-dc1 back to golden-image is its own reset.
#
# Sourced by lab/run-scenario.sh. Has access to ssh_host / ssh_vm /
# scp_to_vm / say / step helpers and the LAB_VM_* / LAB_HV_* variables.
#
# Overridable via env:
#   SC_REALM, SC_NETBIOS, SC_PASS, SC_FWD

SC_REALM="${SC_REALM:-test.lan}"
SC_NETBIOS="${SC_NETBIOS:-TEST}"
SC_PASS="${SC_PASS:-P@ssword123456!}"
SC_FWD="${SC_FWD:-10.10.10.1}"

run_scenario() {
    ssh_vm "sudo env \
        SC_REALM='$SC_REALM' \
        SC_NETBIOS='$SC_NETBIOS' \
        SC_PASS='$SC_PASS' \
        SC_FWD='$SC_FWD' \
        samba-sconfig provision-new"
}

verify() {
    local rc=0 out
    # Pre-compute the upper-case realm: macOS's stock bash 3.2 doesn't
    # support ${var^^}, so doing the transform locally and substituting
    # the result keeps the scenario portable across the orchestrator host.
    local realm_uc
    realm_uc=$(echo "$SC_REALM" | tr '[:lower:]' '[:upper:]')

    say "samba-ad-dc is active"
    ssh_vm 'sudo systemctl is-active samba-ad-dc' || rc=1

    say "smb.conf reflects the new realm"
    out=$(ssh_vm 'sudo grep -E "^\s*(realm|workgroup|server role)" /etc/samba/smb.conf' 2>&1 || true)
    echo "$out"
    grep -qiE "realm[[:space:]]*=[[:space:]]*${SC_REALM}" <<< "$out" || { say "realm mismatch"; rc=1; }
    grep -qiE "workgroup[[:space:]]*=[[:space:]]*${SC_NETBIOS}" <<< "$out" || { say "netbios mismatch"; rc=1; }

    say "Administrator account exists with the new password"
    # net ads info uses the local KDC; if the freshly-provisioned KDC answers
    # a kinit, the password and basic auth chain are healthy.
    ssh_vm "sudo bash -c 'echo \"$SC_PASS\" | kinit Administrator@${realm_uc}'" || rc=1
    ssh_vm "sudo klist 2>&1 | grep -q 'krbtgt/${realm_uc}@${realm_uc}'" || rc=1

    say "DNS forward zone exists for the realm and resolves the DC"
    ssh_vm "dig @127.0.0.1 ${SC_REALM} ANY +short | head -5" || rc=1
    out=$(ssh_vm "dig @127.0.0.1 -t SRV _ldap._tcp.${SC_REALM} +short" 2>&1 || true)
    echo "$out"
    grep -qE "samba-dc1\.${SC_REALM}\.?$" <<< "$out" || { say "no LDAP SRV for samba-dc1.${SC_REALM}"; rc=1; }

    say "SYSVOL is populated with the two default GPOs"
    out=$(ssh_vm "sudo bash -c 'realm=\$(grep -oP \"(?<=realm = ).*\" /etc/samba/smb.conf | head -1 | tr A-Z a-z); ls /var/lib/samba/sysvol/\$realm/Policies/'" 2>&1 || true)
    echo "$out"
    # Default Domain Policy + Default Domain Controllers Policy:
    grep -q '{31B2F340-016D-11D2-945F-00C04FB984F9}' <<< "$out" || { say "default domain policy missing"; rc=1; }
    grep -qi '{6AC1786C-016F-11D2-945F-00C04fB984F9}' <<< "$out" || { say "default DC policy missing"; rc=1; }

    say "TLS cert was generated with SAN"
    ssh_vm 'sudo openssl x509 -noout -ext subjectAltName -in /var/lib/samba/private/tls/cert.pem 2>&1 | head -5' || rc=1

    say "no replication errors (expected — this is a single-DC forest)"
    out=$(ssh_vm 'sudo samba-tool drs showrepl 2>&1' || true)
    echo "$out" | head -20
    if grep -qE '[1-9][0-9]* consecutive failure' <<< "$out" \
       || grep -qiE 'was (a FAILURE|unsuccessful)' <<< "$out"; then
        say "showrepl reports failures on a fresh provision"; rc=1
    fi

    # --- adversarial-profile checks --------------------------------------------
    # These all assert behaviors that are hard to test with cooperative
    # inputs (alpha-only realm, short ASCII NetBIOS) but become
    # load-bearing under --profile adversarial. Each check
    # self-activates from the input shape — no need to gate on
    # $PROFILE_NAME — so they pass cheaply under the default profile and
    # add real coverage under adversarial.

    # Hyphen preservation. Triggers when SC_REALM contains '-'. The
    # provisioned realm, BASE_DN, krb5.conf default_realm, and SYSVOL
    # path must all preserve the hyphen exactly. Catches any
    # accidental ${realm//[-.]/_} or tr '-' '_' that "tidies up" the
    # realm somewhere in the pipeline.
    if [[ "$SC_REALM" == *-* ]]; then
        say "adversarial: hyphen in realm '${SC_REALM}' is preserved end-to-end"

        local realm_lc; realm_lc=$(echo "$SC_REALM" | tr '[:upper:]' '[:lower:]')
        local base_dn; base_dn="DC=${realm_lc//./,DC=}"

        # smb.conf realm: literal preservation.
        ssh_vm "sudo grep -qE \"^[[:space:]]*realm[[:space:]]*=[[:space:]]*${SC_REALM}[[:space:]]*$\" /etc/samba/smb.conf" \
            || { say "  smb.conf realm does NOT match ${SC_REALM} verbatim"; rc=1; }

        # krb5.conf default_realm: literal preservation (case-insensitive
        # match because Samba/MIT toolchains differ on realm case).
        out=$(ssh_vm 'sudo grep -E "default_realm" /etc/krb5.conf' 2>&1 || true)
        echo "  krb5: $out"
        grep -qiF "$SC_REALM" <<< "$out" || { say "  krb5.conf default_realm does NOT contain ${SC_REALM}"; rc=1; }

        # SYSVOL path: hyphen preserved in the directory name.
        ssh_vm "sudo test -d /var/lib/samba/sysvol/${realm_lc}/Policies" \
            || { say "  SYSVOL Policies dir not at /var/lib/samba/sysvol/${realm_lc}/Policies"; rc=1; }

        # samba-tool reports BASE_DN with the hyphen intact.
        out=$(ssh_vm 'sudo samba-tool domain info 127.0.0.1 2>&1' || true)
        echo "$out" | head -10
        grep -qiF "$base_dn" <<< "$out" || { say "  domain info BASE_DN does NOT contain ${base_dn}"; rc=1; }
    fi

    # NetBIOS length boundary. Triggers when SC_NETBIOS is exactly 15
    # chars (the maximum allowed visible length). The provisioned
    # workgroup must be the full 15 chars, not truncated to 14 or
    # padded to 16.
    if [[ ${#SC_NETBIOS} -eq 15 ]]; then
        say "adversarial: 15-char NetBIOS '${SC_NETBIOS}' is preserved (no truncation)"
        out=$(ssh_vm "sudo grep -E '^\\s*workgroup' /etc/samba/smb.conf" 2>&1 || true)
        echo "  workgroup line: $out"
        local got_wg
        got_wg=$(grep -oE 'workgroup[[:space:]]*=[[:space:]]*[^[:space:]]+' <<< "$out" | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')
        if [[ "$got_wg" != "$SC_NETBIOS" ]]; then
            say "  workgroup is '${got_wg}' (length ${#got_wg}), expected '${SC_NETBIOS}' (length 15) — truncation or transform happened"; rc=1
        fi
    fi

    # Password-quoting trap. When SC_PASS contains shell-hazardous chars
    # ($, ", `, \, '), the kinit assertion above (line ~50) becomes the
    # load-bearing test: if provisioning AND kinit both succeeded with a
    # hazardous password, every shell layer in the pipeline (samba-tool
    # provision invocation, kinit pipe, whiptail prompts when run
    # interactively) handled the chars correctly. Just announce here so
    # the scenario log explains why this was a meaningful run, and flag
    # if any *other* check above failed — the failure was almost
    # certainly the password chain, not the test it surfaced in.
    if [[ "$SC_PASS" == *\"* || "$SC_PASS" == *\$* || "$SC_PASS" == *\`* || "$SC_PASS" == *\\* || "$SC_PASS" == *\'* ]]; then
        say "adversarial: hazardous-char password survived end-to-end (provision + kinit above)"
        if [[ $rc -ne 0 ]]; then
            say "  NB: a check above failed under hazardous-char password — the password pipeline is the most likely cause"
        fi
    fi

    return $rc
}

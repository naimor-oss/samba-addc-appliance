# shellcheck shell=bash
# lab/scenarios/smoke-prepared-image.sh - verify the golden appliance image
# before any domain operation.
#
# This scenario should run against a freshly reverted `golden-image` checkpoint.
# It verifies that prepare-image.sh produced a clean, unprovisioned appliance
# base: tools installed, Samba DC not running yet, no smb.conf, and no
# deployment-specific time/domain configuration baked into the image.

run_scenario() {
    # Nothing to mutate. The runner has already reverted the VM and pushed the
    # current scripts, so verification can inspect the prepared image directly.
    ssh_vm 'hostname; ip -4 addr show scope global | head -3'
}

verify() {
    local rc=0 out

    say "samba-sconfig is installed"
    ssh_vm 'test -x /usr/local/sbin/samba-sconfig && sudo /usr/local/sbin/samba-sconfig --help | head -20' || rc=1

    say "required appliance tools are present"
    # Outer single quotes preserve the literal $c through ssh; the \$c
    # below survives the remote shell's parsing of the double-quoted
    # bash -lc argument and is only expanded by bash -lc's loop.
    out=$(ssh_vm 'sudo bash -lc "for c in samba-tool samba smbclient ldapsearch nft pwsh chronyd dig ssh-keygen; do printf \"%s \" \"\$c\"; command -v \"\$c\" || exit 1; done"' 2>&1 || true)
    echo "$out"
    if grep -qi 'not found' <<< "$out" || ! grep -q 'samba-tool' <<< "$out"; then
        rc=1
    fi

    say "console setup supports pasted and manually typed SSH keys"
    ssh_vm 'grep -q "^read_pasted_ssh_key()" /usr/local/sbin/samba-init &&
            grep -q "^read_typed_ed25519_key()" /usr/local/sbin/samba-init &&
            grep -q "KVM Console Paste" /usr/local/sbin/samba-init &&
            grep -q "Ruler: 12345678901234567" /usr/local/sbin/samba-init &&
            grep -q "ssh-keygen -lf" /usr/local/sbin/samba-init' || rc=1

    say "Samba AD DC is not provisioned yet"
    ssh_vm 'test ! -f /etc/samba/smb.conf' || rc=1
    ssh_vm 'sudo systemctl is-active --quiet samba-ad-dc && exit 1 || exit 0' || rc=1

    say "member/file-server daemons are not enabled"
    out=$(ssh_vm 'for svc in smbd nmbd winbind; do printf "%s: " "$svc"; systemctl is-enabled "$svc" 2>/dev/null || true; done' 2>&1 || true)
    echo "$out"
    if grep -qE ': enabled$' <<< "$out"; then
        rc=1
    fi

    say "Kerberos and chrony are deployment-neutral skeletons"
    ssh_vm 'grep -q "YOURREALM.LAN" /etc/krb5.conf' || rc=1
    out=$(ssh_vm 'grep -E "^(server|pool) " /etc/chrony/chrony.conf || true' 2>&1 || true)
    echo "$out"
    if grep -qE 'time\.cloudflare|time\.google|debian\.pool|^server |^pool ' <<< "$out"; then
        rc=1
    fi

    say "network is alive through the lab router"
    ssh_vm 'ping -c 1 -W 2 10.10.10.1 >/dev/null' || rc=1
    ssh_vm 'getent hosts debian.org >/dev/null' || rc=1

    say "firstboot freshness check completed without an apt lock failure"
    out=$(ssh_vm 'sudo grep "apt: " /var/log/samba-firstboot.log | tail -1' 2>&1 || true)
    echo "$out"
    grep -q 'apt: image is current (0 upgrades pending)' <<< "$out" || rc=1

    say "SSH login has one dynamic Samba status and no duplicate static banner"
    ssh_vm 'test ! -s /etc/motd' || rc=1
    ssh_vm 'test -x /etc/update-motd.d/15-samba-net-status' || rc=1

    say "first-launch marker has not been consumed"
    ssh_vm 'test ! -f /var/lib/samba-sconfig/first-boot-done' || rc=1

    return "$rc"
}

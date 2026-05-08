#!/usr/bin/env bash
#===============================================================================
# samba-sconfig — Samba AD DC Appliance Configuration Tool
#
# Whiptail TUI modeled after Windows Server Core's sconfig.
# Handles deployment configuration and management of a Samba AD DC
# on Debian 13 (Trixie).
#
# Usage: sudo samba-sconfig
#
# Maintainer map:
#   - TUI menu functions collect input and confirm destructive operations.
#   - Shared helpers do the real work and are also used by the headless CLI at
#     the bottom of this file.
#   - Keep deployment-specific decisions out of prepare-image.sh. If a value
#     depends on realm, source DC, client subnet, or role, set it here.
#   - Samba/Windows interop has several non-obvious requirements. Comments near
#     probe_forest_fl, register_own_ptr, seed_sysvol, and chrony explain the
#     failure modes those helpers prevent.
#===============================================================================
set -uo pipefail

readonly VERSION="1.1.0"
readonly SCRIPT_NAME="samba-sconfig"
readonly WT_HEIGHT=22
readonly WT_WIDTH=76
readonly WT_MENU_HEIGHT=14

#===============================================================================
# UTILITIES
#===============================================================================
# Source the shared appliance-core libs that prepare-image.sh §18b
# vendored to /usr/local/lib/appliance-core/. The libs are idempotent
# (sentinel-guarded), so sourcing every time samba-sconfig starts is
# cheap and keeps the dependency direction explicit. If the libs
# weren't vendored (older image, broken build), warn-and-continue —
# the sconfig still works for paths that don't depend on them.
APPCORE_LIBS=/usr/local/lib/appliance-core
if [[ -d "$APPCORE_LIBS" ]]; then
    [[ -f "$APPCORE_LIBS/identity.sh"   ]] && source "$APPCORE_LIBS/identity.sh"
    [[ -f "$APPCORE_LIBS/tui.sh"        ]] && source "$APPCORE_LIBS/tui.sh"
    [[ -f "$APPCORE_LIBS/hostname.sh"   ]] && source "$APPCORE_LIBS/hostname.sh"
    [[ -f "$APPCORE_LIBS/detect-net.sh" ]] && source "$APPCORE_LIBS/detect-net.sh"
    [[ -f "$APPCORE_LIBS/netconfig.sh"  ]] && source "$APPCORE_LIBS/netconfig.sh"
fi

die()  { whiptail --msgbox "FATAL: $*" 10 60; exit 1; }
info() { whiptail --msgbox "$*" 12 64; }
yesno(){ whiptail --yesno "$*" 10 60; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Run as root (sudo samba-sconfig)." >&2
        exit 1
    fi
}

get_hostname()  { hostname -s 2>/dev/null || echo "(not set)"; }
get_fqdn()      { hostname -f 2>/dev/null || echo "(not set)"; }
get_domain()    { dnsdomainname 2>/dev/null || echo "(not set)"; }
get_ip()        { ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+[.\d/]+' | head -1 || echo "(not set)"; }
get_gateway()   { ip route show default | awk '/default/{print $3}' | head -1 || echo "(not set)"; }
get_iface()     { ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1 || \
                  ip link show | awk -F: '/^[0-9]+:/{if($2!~"lo") print $2}' | tr -d ' ' | head -1; }

is_provisioned() { [[ -f /etc/samba/smb.conf ]] && grep -q 'server role.*active directory' /etc/samba/smb.conf 2>/dev/null; }
is_addc_running() { systemctl is-active samba-ad-dc &>/dev/null; }

# Resolve an FQDN to an IPv4 address using the CURRENT system resolver.
# If the argument is already an IPv4 literal, return it unchanged. Callers
# must use this BEFORE rewriting /etc/resolv.conf, otherwise the new
# nameserver (the target DC, which may not yet be reachable or ready) gets
# asked and the lookup silently fails. The FQDN string then lands in
# resolv.conf as-is, which kills DNS entirely and the join errors out at
# "Looking for DC".
resolve_dc_ip() {
    local host="$1"
    if [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        printf '%s' "$host"
        return 0
    fi
    local ip
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}')
    [[ -n "$ip" ]] || return 1
    printf '%s' "$ip"
}

# Query the target DC's rootDSE forestFunctionality attribute and return the
# matching Samba `ad dc functional level` string. rootDSE is queried
# anonymously: per LDAP/AD convention it remains readable even when the Windows
# security baseline requires LDAP signing for normal binds.
#
# This prevents a costly false lead. Samba's historical default is 2008_R2;
# Windows Server 2025 forests are typically FL 2016. If we let Samba advertise
# the old default, `samba-tool domain join` can fail with
# WERR_DS_INCOMPATIBLE_VERSION during NTDS Settings creation, which looks like
# a schema or permission problem until you inspect the Windows event log.
#
#   Input:  $1 = DC hostname or IP
#   Stdout: one of 2003, 2008, 2008_R2, 2012, 2012_R2, 2016
#   Return: 0 on success, 1 on query failure (stdout still prints 2008_R2)
# Take exclusive ownership of /etc/resolv.conf. systemd-resolved (the
# pre-provision DNS path on the appliance) manages /etc/resolv.conf as a
# symlink to its own stub file and rewrites that target on its own
# schedule. Manual writes during join/provision get silently clobbered
# and Samba ends up using stale DNS — symptoms range from
# WERR_NO_LOGON_SERVERS during initial replication to broken Kerberos
# right after a successful join.
#
# Call this immediately before any `> /etc/resolv.conf` write in the
# join/provision path. Idempotent.
take_over_resolv_conf() {
    if systemctl is-active systemd-resolved &>/dev/null 2>&1; then
        systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
    fi
    if [[ -L /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf
    fi
}

probe_forest_fl() {
    local dc="$1"
    local fl_num
    fl_num=$(ldapsearch -x -LLL -H "ldap://${dc}" -s base -b "" forestFunctionality 2>/dev/null \
        | awk '/^forestFunctionality:/ { print $2 }')
    if [[ -z "$fl_num" ]]; then
        echo "2008_R2"
        return 1
    fi
    case "$fl_num" in
        2)  echo "2003"    ;;
        3)  echo "2008"    ;;
        4)  echo "2008_R2" ;;
        5)  echo "2012"    ;;
        6)  echo "2012_R2" ;;
        7)  echo "2016"    ;;
        *)  echo "2016"    ;;   # Samba 4.22 caps at 2016 — advertise max we support
    esac
}

get_realm() {
    is_provisioned && grep -oP '(?<=realm = ).*' /etc/samba/smb.conf 2>/dev/null | head -1 || echo "(not provisioned)"
}

get_netbios() {
    is_provisioned && grep -oP '(?<=workgroup = ).*' /etc/samba/smb.conf 2>/dev/null | head -1 || echo "(not provisioned)"
}

get_dc_role() {
    if ! is_provisioned; then echo "Not provisioned"; return; fi
    if is_addc_running; then echo "AD DC (Running)"; else echo "AD DC (Stopped)"; fi
}

get_update_policy() {
    if [[ ! -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
        echo "Not configured"
        return
    fi
    local update_list unattended
    update_list=$(grep -oP '(?<=Update-Package-Lists ").*(?=")' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null)
    unattended=$(grep -oP '(?<=Unattended-Upgrade ").*(?=")' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null)
    if [[ "$unattended" == "1" && "$update_list" == "1" ]]; then
        if grep -q 'origin=Debian,codename=.*-security' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null && \
           ! grep -q '^\s*"origin=Debian,codename=\${distro_codename}' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
            echo "Security only"
        else
            echo "Full automatic"
        fi
    else
        echo "Manual"
    fi
}

#===============================================================================
# FIRST-LAUNCH WIZARD
#
# Run once per image, right when the admin first opens sconfig on a freshly
# prepared VM. Covers the tasks that are easy to forget and hard to recover
# from later: check connectivity, offer updates, prompt to pin the DHCP lease
# as a static IP before provisioning/joining a domain.
#===============================================================================
FIRST_BOOT_MARKER='/var/lib/samba-sconfig/first-boot-done'

first_boot_wizard() {
    [[ -f "$FIRST_BOOT_MARKER" ]] && return
    mkdir -p "$(dirname "$FIRST_BOOT_MARKER")"

    whiptail --title "Welcome to samba-sconfig" --msgbox \
        "This looks like a freshly-prepared appliance image.\n\nThe first-launch wizard will offer to:\n  1. Check your internet connection\n  2. Install available updates\n  3. Pin the current DHCP lease as a static IP\n\nYou can skip any step and come back via the normal menus." \
        14 64

    # 1. Connectivity probe
    if ping -c 1 -W 2 -q 1.1.1.1 &>/dev/null; then
        whiptail --title "Connectivity" --msgbox \
            "Internet reachable.\n\nGateway: $(get_gateway)\nDNS:     $(get_current_dns)" 10 60
    else
        whiptail --title "Connectivity" --msgbox \
            "Cannot reach 1.1.1.1.\n\nThis lab expects DHCP from the router. Check that the VM is on the Lab-NAT switch and the router VM is up. Skipping update offer." 12 64
        touch "$FIRST_BOOT_MARKER"
        return
    fi

    # 2. Updates
    if whiptail --title "System Updates" --yesno \
        "Check for and install available updates now?\n\nThis runs 'apt update' and 'apt full-upgrade -y'. Full-upgrade is\nrequired so kernel metapackages (linux-image-cloud-amd64) actually\nget pulled — plain 'apt upgrade' silently keeps them back.\nTakes 1-3 min on a clean image." 14 70; then
        clear
        echo "[sconfig] apt update..."
        apt-get update
        echo "[sconfig] apt full-upgrade..."
        DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
        if [[ -f /var/run/reboot-required ]]; then
            echo
            echo "[sconfig] REBOOT REQUIRED — a kernel or library that's currently"
            echo "[sconfig] loaded was upgraded. The first-boot wizard will reboot"
            echo "[sconfig] for you after the rest of the wizard, or pick"
            echo "[sconfig] 'Reboot / Shutdown' from the main menu later."
        fi
        echo "[sconfig] done — press Enter to continue"
        read -r _
    fi

    # 3. Pin DHCP lease as static. The lab uses DHCP reservations to mimic a
    # real appliance landing on an existing LAN, but AD DCs still need stable
    # addressing. Writing a static config here gives production-like behavior
    # after first boot while keeping initial install simple.
    local addr_source
    addr_source=$(get_addr_source)
    if [[ "$addr_source" == "dhcp" ]]; then
        if whiptail --title "Network" --yesno \
            "Interface is on DHCP ($(get_ip | cut -d/ -f1)).\n\nAn AD DC needs a stable IP. Pin the current lease as static now?" 12 64; then
            local iface; iface=$(get_iface)
            local ip mask gw dns
            ip=$(get_ip | cut -d/ -f1); mask=$(get_ip | cut -d/ -f2)
            gw=$(get_gateway); dns=$(get_current_dns)
            cat > /etc/network/interfaces << NETEOF
# Managed by samba-sconfig (first-boot pin)
auto lo
iface lo inet loopback

auto ${iface}
iface ${iface} inet static
    address ${ip}/${mask}
    gateway ${gw}
NETEOF
            take_over_resolv_conf
            printf "nameserver %s\n" "$dns" > /etc/resolv.conf
            whiptail --title "Network" --msgbox \
                "Static pin written:\n  ${ip}/${mask}\n  gw=${gw}  dns=${dns}\n\nEffective on next boot (or systemctl restart networking)." 12 64
        fi
    fi

    touch "$FIRST_BOOT_MARKER"
}

#===============================================================================
# MAIN MENU
#===============================================================================
main_menu() {
    first_boot_wizard
    while true; do
        local hostname fqdn ip_addr dc_role realm_str
        hostname=$(get_hostname)
        fqdn=$(get_fqdn)
        ip_addr=$(get_ip)
        dc_role=$(get_dc_role)
        realm_str=$(get_realm)

        local choice
        choice=$(whiptail --title "Samba AD DC Configuration [$hostname] v${VERSION}" \
            --menu "\n  Host: $fqdn  |  IP: $ip_addr\n  Role: $dc_role  |  Realm: $realm_str\n" \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "System Configuration" \
            "2" "Domain Operations" \
            "3" "Post-Domain Setup" \
            "4" "SYSVOL Replication" \
            "5" "DFS Namespace Server" \
            "6" "Security Hardening" \
            "7" "Diagnostics & Sanity Check" \
            "8" "Service Management" \
            "9" "Reboot / Shutdown" \
            "Q" "Exit" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) menu_system_config ;;
            2) menu_domain_ops ;;
            3) menu_post_domain ;;
            4) menu_sysvol_sync ;;
            5) menu_dfs ;;
            6) menu_hardening ;;
            7) menu_diagnostics ;;
            8) menu_services ;;
            9) menu_power ;;
            Q|q) clear; exit 0 ;;
        esac
    done
}

#===============================================================================
# 1. SYSTEM CONFIGURATION
#===============================================================================
menu_system_config() {
    while true; do
        local update_policy
        update_policy=$(get_update_policy)
        local choice
        choice=$(whiptail --title "System Configuration" \
            --menu "Hostname: $(get_fqdn)\nIP: $(get_ip) | GW: $(get_gateway)\nUpdates: $update_policy" \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Set Hostname" \
            "2" "Configure Network (Static IP)" \
            "3" "Set Timezone" \
            "4" "Configure System Updates" \
            "5" "Run Updates Now" \
            "6" "Show System Info" \
            "B" "Back to Main Menu" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) config_hostname ;;
            2) config_network ;;
            3) config_timezone ;;
            4) config_updates ;;
            5) run_updates_now ;;
            6) show_system_info ;;
            B|b) return ;;
        esac
    done
}

config_hostname() {
    # Hostname changes after a provision/join break Kerberos keytabs,
    # machine account, SPNs, and replication identity. Block them and
    # send the operator to Domain Operations to demote first.
    if is_provisioned; then
        info "This DC is already provisioned/joined.\n\nChanging the hostname here would break Kerberos, the machine account, and replication. To rename, demote first via Domain Operations, set the new hostname, then re-provision or re-join."
        return
    fi

    # The actual rename flow lives in the appliance-core hostname.sh
    # lib (live DHCP/PTR/dnsdomainname domain detection, NetBIOS-rules
    # short-name validation, safe /etc/hosts rewrite). The post-provision
    # guard above is the only product-specific bit; everything else is
    # shared with smb-proxy and any future appliance.
    if ! command -v appcore_hostname_change_tui >/dev/null 2>&1; then
        info "appliance-core libs not vendored on this image.\nRebuild via lab/build-fresh-base.sh, or copy ../appliance-core/lib/*.sh to /usr/local/lib/appliance-core/ by hand."
        return
    fi

    if appcore_hostname_change_tui; then
        info "Hostname set to: ${APPCORE_HOSTNAME_NEW_FQDN}\n\nReboot recommended so all services pick it up."
    fi
}

get_addr_source() {
    # Report whether the default interface currently has a DHCP lease,
    # a static assignment, or nothing. Used by config_network to decide
    # what to offer the user.
    local iface="${1:-$(get_iface)}"
    [[ -z "$iface" ]] && { echo none; return; }
    if ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'dynamic'; then
        echo dhcp
    elif ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
        echo static
    else
        echo none
    fi
}

get_current_dns() {
    # First non-comment nameserver in /etc/resolv.conf
    awk '/^nameserver[[:space:]]/ { print $2; exit }' /etc/resolv.conf 2>/dev/null
}

config_network() {
    # Delegate to appliance-core's netconfig.sh. Replaces a previously-
    # broken inline implementation that wrote /etc/network/interfaces
    # — Debian 13 with systemd-networkd + netplan silently ignores
    # that file, so operator clicks here had no effect on real
    # network state. The lib emits real netplan that the kernel's
    # network stack actually honors.
    if ! command -v appcore_netconfig_change_tui_single_nic >/dev/null 2>&1; then
        info "appliance-core netconfig lib not vendored on this image.\nRebuild via lab/build-fresh-base.sh, or copy ../appliance-core/lib/netconfig.sh\nto /usr/local/lib/appliance-core/ by hand."
        return
    fi
    appcore_netconfig_change_tui_single_nic \
        /etc/netplan/60-samba-init.yaml \
        'e*'
}

config_timezone() { dpkg-reconfigure tzdata; }

config_updates() {
    local choice
    choice=$(whiptail --title "System Update Policy" \
        --menu "Current policy: $(get_update_policy)\n\nSelect how this server should handle system updates." \
        $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
        "1" "Manual — no automatic updates (I will run updates myself)" \
        "2" "Security Only — auto-install critical security patches" \
        "3" "Full Automatic — auto-install all stable updates" \
        "B" "Back" \
        3>&1 1>&2 2>&3) || return

    case "$choice" in
        1) set_update_policy_manual ;;
        2) set_update_policy_security ;;
        3) set_update_policy_full ;;
        B|b) return ;;
    esac
}

set_update_policy_manual() {
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "7";
EOF
    info "Update policy: MANUAL\n\nPackage lists refresh daily, but nothing installs automatically.\nRun updates manually from this menu or via apt."
}

set_update_policy_security() {
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    # Configure unattended-upgrades for security only
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

Unattended-Upgrade::Package-Blacklist {
    // Prevent Samba from being upgraded unattended (could break AD)
    "samba";
    "samba-ad-dc";
    "winbind";
    "libnss-winbind";
    "libpam-winbind";
    "krb5-user";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Email notification (configure if needed)
//Unattended-Upgrade::Mail "root";
//Unattended-Upgrade::MailReport "on-change";

// Auto-reboot if needed (disabled by default for a DC)
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    systemctl enable unattended-upgrades 2>/dev/null || true

    info "Update policy: SECURITY ONLY\n\nOnly Debian security patches auto-install.\nSamba/Kerberos/Winbind packages are blacklisted from auto-update\n(upgrade those manually to avoid breaking AD).\n\nAuto-reboot is DISABLED."
}

set_update_policy_full() {
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "origin=Debian,codename=${distro_codename},label=Debian";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-updates,label=Debian";
};

Unattended-Upgrade::Package-Blacklist {
    "samba";
    "samba-ad-dc";
    "winbind";
    "libnss-winbind";
    "libpam-winbind";
    "krb5-user";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    systemctl enable unattended-upgrades 2>/dev/null || true

    info "Update policy: FULL AUTOMATIC\n\nAll Debian stable + security updates auto-install.\nSamba/Kerberos/Winbind are still blacklisted.\nAuto-reboot is DISABLED."
}

run_updates_now() {
    if yesno "Run apt update && apt full-upgrade now?\n\nFull-upgrade is required to apply kernel metapackage updates\n(linux-image-cloud-amd64) — plain 'apt upgrade' silently keeps\nthem back. Runs interactively so you can review."; then
        clear
        echo "[sconfig] apt full-upgrade..."
        echo "[sconfig]   note: full-upgrade can install new dependencies"
        echo "[sconfig]   (e.g. new kernel ABI). Plain 'apt-get upgrade'"
        echo "[sconfig]   would silently keep them back."
        echo
        if command -v appcore_apt_run_full_upgrade >/dev/null 2>&1; then
            appcore_apt_run_full_upgrade
        else
            apt-get update && apt-get full-upgrade
        fi
        echo
        echo "=============================================================="
        local rb=""
        if command -v appcore_apt_reboot_banner_line >/dev/null 2>&1; then
            rb=$(appcore_apt_reboot_banner_line)
        elif [[ -f /var/run/reboot-required ]]; then
            rb="REBOOT REQUIRED"
        fi
        if [[ -n "$rb" ]]; then
            echo "  $rb"
            echo "  A kernel or library that's currently loaded was upgraded."
            echo "  Pick 'Reboot / Shutdown' from the main menu (or run"
            echo "  'sudo reboot') to apply."
        else
            echo "  Done. No reboot required."
        fi
        echo "=============================================================="
        echo "Press Enter to return to samba-sconfig..."
        read -r
    fi
}

show_system_info() {
    local info_text
    info_text=$(cat << EOF
Hostname (FQDN): $(get_fqdn)
Hostname (short): $(get_hostname)
IP Address:       $(get_ip)
Gateway:          $(get_gateway)
Interface:        $(get_iface)
DNS Domain:       $(get_domain)

Kernel:           $(uname -r)
Debian:           $(cat /etc/debian_version 2>/dev/null)
Virtualization:   $(systemd-detect-virt 2>/dev/null || echo "unknown")
Uptime:           $(uptime -p 2>/dev/null)

Samba:            $(samba --version 2>/dev/null || echo "not installed")
PowerShell:       $(pwsh --version 2>/dev/null || echo "not installed")
DC Role:          $(get_dc_role)
Realm:            $(get_realm)
NetBIOS:          $(get_netbios)
Update Policy:    $(get_update_policy)
EOF
)
    whiptail --title "System Information" --scrolltext --msgbox "$info_text" 24 70
}

#===============================================================================
# 2. DOMAIN OPERATIONS
#===============================================================================
menu_domain_ops() {
    if is_provisioned; then
        info "Already provisioned.\n\nRealm: $(get_realm)\nNetBIOS: $(get_netbios)\n\nTo re-provision, remove /etc/samba/smb.conf and\n/var/lib/samba/private/ contents first."
        return
    fi

    local choice
    choice=$(whiptail --title "Domain Operations" \
        --menu "Select DC role. WARNING: These operations are destructive." \
        $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
        "1" "Create New Forest & Domain" \
        "2" "Join as Additional DC (Backup)" \
        "3" "Join as Read-Only DC (RODC)" \
        "B" "Back" \
        3>&1 1>&2 2>&3) || return

    case "$choice" in
        1) domain_provision_new ;;
        2) domain_join_dc ;;
        3) domain_join_rodc ;;
        B|b) return ;;
    esac
}

collect_domain_info() {
    DC_REALM=$(whiptail --inputbox \
        "AD Realm (UPPERCASE DNS domain name).\n\nExamples: HOME.LAN, CORP.CONTOSO.COM\nDo NOT use .local" \
        12 64 "" 3>&1 1>&2 2>&3) || return 1
    [[ -z "$DC_REALM" ]] && return 1
    DC_REALM="${DC_REALM^^}"
    [[ "$DC_REALM" == *.LOCAL ]] && { info ".LOCAL conflicts with mDNS."; return 1; }

    local default_netbios="${DC_REALM%%.*}"
    DC_NETBIOS=$(whiptail --inputbox "NetBIOS (short) domain name. Max 15 chars, no dots." \
        10 64 "$default_netbios" 3>&1 1>&2 2>&3) || return 1
    DC_NETBIOS="${DC_NETBIOS^^}"

    DC_DNS_FORWARDER=$(whiptail --inputbox "DNS forwarder (upstream DNS for external names):" \
        10 64 "1.1.1.1" 3>&1 1>&2 2>&3) || return 1

    return 0
}

# Provisioning a new forest — prompt for the password to CREATE for the
# built-in Administrator. Username is fixed (Administrator) because this is
# the well-known account Samba creates during `domain provision`.
collect_new_admin_password() {
    DC_ADMIN_USER="Administrator"
    DC_ADMIN_PASS=$(whiptail --passwordbox \
        "Choose a password for the new forest's built-in Administrator account.\n\nMinimum 8 characters; Samba's default policy requires mixed case, digits, and a symbol." \
        14 68 3>&1 1>&2 2>&3) || return 1
    [[ ${#DC_ADMIN_PASS} -lt 8 ]] && { info "Password too short (min 8 chars)."; return 1; }

    local pass_confirm
    pass_confirm=$(whiptail --passwordbox "Confirm password:" 10 64 3>&1 1>&2 2>&3) || return 1
    [[ "$DC_ADMIN_PASS" != "$pass_confirm" ]] && { info "Passwords don't match."; return 1; }

    return 0
}

# Joining an existing domain — prompt for the EXISTING credentials of a
# domain account with rights to add a DC. Defaults to Administrator but any
# account in Domain Admins (or with delegated join rights) works.
collect_join_credentials() {
    DC_ADMIN_USER=$(whiptail --inputbox \
        "Username of a domain administrator with permission to join a new DC to ${DC_NETBIOS}.\n\nDefaults to Administrator. Any account in Domain Admins (or with delegated join rights) will work." \
        13 68 "Administrator" 3>&1 1>&2 2>&3) || return 1
    [[ -z "$DC_ADMIN_USER" ]] && { info "Admin username required."; return 1; }

    DC_ADMIN_PASS=$(whiptail --passwordbox \
        "Enter the current password for ${DC_NETBIOS}\\\\${DC_ADMIN_USER} (these are the existing credentials used to authenticate the join — not a new password):" \
        12 68 3>&1 1>&2 2>&3) || return 1
    [[ -z "$DC_ADMIN_PASS" ]] && { info "Password required."; return 1; }

    return 0
}

write_krb5_conf() {
    cat > /etc/krb5.conf << KRBEOF
[libdefaults]
  default_realm = ${1}
  dns_lookup_kdc = true
  dns_lookup_realm = false
KRBEOF
}

apply_hardening_to_smb_conf() {
    local smb="/etc/samba/smb.conf"
    [[ -f "$smb" ]] || return
    grep -q '# --- sconfig hardening ---' "$smb" 2>/dev/null && return

    # Insert hardening INTO the [global] section. Appending to EOF lands
    # after [sysvol]/[netlogon], which makes testparm complain "Global
    # parameter X found in service section!" and in some cases the value
    # is actually ignored. Samba's post-provision smb.conf uses tab-indent,
    # so match that.
    local tmp
    tmp=$(mktemp)
    awk '
        BEGIN { inserted = 0 }
        /^\[global\][[:space:]]*$/ && !inserted {
            print
            print "\t# --- sconfig hardening ---"
            print "\tserver signing = mandatory"
            print "\tclient signing = mandatory"
            print "\tserver min protocol = SMB3_00"
            print "\tclient min protocol = SMB3_00"
            print "\tldap server require strong auth = yes"
            print "\tkerberos encryption types = strong"
            print "\tntlm auth = mschapv2-and-ntlmv2-only"
            print "\ttls enabled = yes"
            print "\ttls priority = NORMAL:-VERS-ALL:+VERS-TLS1.2:+VERS-TLS1.3"
            print "\tlog level = 1 auth_audit:3 auth_json_audit:3"
            print "\tallow dns updates = secure only"
            inserted = 1
            next
        }
        { print }
    ' "$smb" > "$tmp"

    if [[ $(wc -l < "$tmp") -gt $(wc -l < "$smb") ]]; then
        mv "$tmp" "$smb"
    else
        # Fallback: no [global] line found — leave original alone and warn
        rm -f "$tmp"
        echo "[sconfig] WARN: [global] section not found in $smb — hardening NOT applied" >&2
        return 1
    fi
}

# `samba-tool ntacl sysvolreset` can loop forever emitting
# "idmap range not specified for domain '*'" when smb.conf has no idmap
# block for the catch-all domain. Samba's post-provision / post-join
# template doesn't include one; inject a sensible default so sysvolreset
# (and any other tool that needs SID→POSIX translation for foreign SIDs)
# can progress. No-op on subsequent calls.
ensure_idmap_config() {
    local smb="/etc/samba/smb.conf"
    [[ -f "$smb" ]] || return 0
    grep -qE '^[[:space:]]*idmap config \* : backend' "$smb" 2>/dev/null && return 0

    local tmp
    tmp=$(mktemp)
    awk '
        BEGIN { inserted = 0 }
        /^\[global\][[:space:]]*$/ && !inserted {
            print
            print "\tidmap config * : backend = tdb"
            print "\tidmap config * : range = 3000000-4000000"
            inserted = 1
            next
        }
        { print }
    ' "$smb" > "$tmp"

    if [[ $(wc -l < "$tmp") -gt $(wc -l < "$smb") ]]; then
        mv "$tmp" "$smb"
    else
        rm -f "$tmp"
        echo "[sconfig] WARN: [global] not found in $smb — idmap config NOT added" >&2
        return 1
    fi
}

post_provision_setup() {
    local realm="$1" dns_fwd="$2"
    local realm_lower="${realm,,}"

    # Samba tools look in private/krb5.conf, while admins expect the system
    # Kerberos config in /etc. Use one source of truth so the TUI, CLI, kinit,
    # and Samba agree after both provision and join.
    rm -f /var/lib/samba/private/krb5.conf
    ln -s /etc/krb5.conf /var/lib/samba/private/krb5.conf

    if ! grep -q "dns forwarder" /etc/samba/smb.conf 2>/dev/null; then
        sed -i "/\[global\]/a\\        dns forwarder = ${dns_fwd}" /etc/samba/smb.conf
    fi

    ensure_idmap_config

    take_over_resolv_conf
    cat > /etc/resolv.conf << DNSEOF
search ${realm_lower}
nameserver 127.0.0.1
DNSEOF

    systemctl unmask samba-ad-dc
    systemctl enable samba-ad-dc
    systemctl start samba-ad-dc
    sleep 3
}

# Seed /var/lib/samba/sysvol/ from the source DC immediately after joining.
# Samba doesn't implement DFSR, so without a bootstrap copy the GPO files
# under Policies/ are empty until sysvol-sync runs on a schedule. We use
# smbclient (not rsync-over-SSH) because Windows DCs rarely have sshd.
#
#   Input:  $1 source DC (FQDN), $2 netbios domain, $3 admin username,
#           $4 admin password, $5 realm (lowercased used for the SYSVOL
#           subtree name)
seed_sysvol() {
    local src_dc="$1" netbios="$2" admin_user="$3" admin_pass="$4" realm="$5"
    local realm_lower="${realm,,}"
    local tmpdir
    tmpdir=$(mktemp -d)

    echo "[sconfig] seeding SYSVOL from //${src_dc}/sysvol/${realm_lower} ..."
    if smbclient "//${src_dc}/sysvol" \
            -U "${netbios}\\${admin_user}%${admin_pass}" \
            -c "recurse ON; prompt OFF; lcd ${tmpdir}; mget ${realm_lower}" \
            >/dev/null 2>&1; then
        if [[ -d "${tmpdir}/${realm_lower}" ]]; then
            cp -a "${tmpdir}/${realm_lower}/." "/var/lib/samba/sysvol/${realm_lower}/"
            echo "[sconfig] SYSVOL seeded. Resetting NTACLs..."
            samba-tool ntacl sysvolreset 2>&1 | sed 's/^/[ntacl] /' || true
            rm -rf "$tmpdir"
            return 0
        fi
    fi
    echo "[sconfig] WARN: SYSVOL seed failed (smbclient or copy). Policies/ will be empty"
    echo "[sconfig]       until sysvol-sync runs. Verify SMB signing + creds on $src_dc."
    rm -rf "$tmpdir"
    return 1
}

# Re-point chrony at a domain time source. Called post-join / post-provision.
# The image skeleton has no NTP servers baked in. That avoids public-pool
# assumptions and lets this function use the correct source: the existing DC
# when joining, or a chosen upstream/client subnet when this host is the first
# DC in a new deployment.
configure_chrony_for_domain() {
    local ntp_source="$1" subnet="${2:-}"
    local conf="/etc/chrony/chrony.conf"

    # Strip any prior sconfig-managed block
    sed -i '/# --- sconfig-managed chrony ---/,/# --- end sconfig ---/d' "$conf" 2>/dev/null

    cat >> "$conf" <<CHRONYEOF
# --- sconfig-managed chrony ---
server ${ntp_source} iburst
$( [[ -n "$subnet" ]] && echo "allow ${subnet}" )
# --- end sconfig ---
CHRONYEOF
    systemctl restart chrony 2>/dev/null || true
    echo "[sconfig] chrony repointed at ${ntp_source}${subnet:+ (serving $subnet)}"
}

# Register this host's PTR in the target forest's reverse zone so Windows DC
# KCC replication works. The forward records created by Samba are not enough
# in the WS2025 lab: Windows can resolve the source DC GUID CNAME and A record
# but still cache replication error 8524 when the source IP has no PTR.
#
#   Input:  $1 target DC (FQDN or IP, usually the source DC we joined from)
#           $2 NetBIOS domain (for `${NETBIOS}\${admin_user}`)
#           $3 admin username (e.g. Administrator)
#           $4 admin password
#           $5 realm (DNS domain) — used to compose this host's FQDN
#   Return: 0 on success, 1 on any failure (including zone not present).
register_own_ptr() {
    local target_dc="$1" netbios="$2" admin_user="$3" admin_pass="$4" realm="$5"
    local my_ip my_fqdn reverse_zone reverse_name a b c d

    my_ip=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    [[ -z "$my_ip" ]] && { echo "[sconfig] WARN: no IPv4 address — skipping PTR registration"; return 1; }
    IFS='.' read -r a b c d <<< "$my_ip"
    reverse_zone="${c}.${b}.${a}.in-addr.arpa"
    reverse_name="$d"
    my_fqdn="$(hostname -s).${realm,,}"

    echo "[sconfig] registering PTR  ${reverse_name}.${reverse_zone}  →  ${my_fqdn}."
    local out ptr_ok=false
    if out=$(samba-tool dns add "$target_dc" "$reverse_zone" "$reverse_name" PTR "${my_fqdn}." \
                -U"${netbios}\\${admin_user}" --password="$admin_pass" 2>&1); then
        echo "[sconfig] PTR registered on $target_dc"
        ptr_ok=true
    elif grep -qiE "already exist|DNS_ERROR_RECORD_ALREADY_EXISTS" <<< "$out"; then
        echo "[sconfig] PTR already present on $target_dc"
        ptr_ok=true
    fi

    if $ptr_ok; then
        # Force KCC on the source DC to re-evaluate the replica link now that
        # PTR exists. Without this, the stale 8524 from the brief window
        # between `samba-tool domain join` completing and the PTR being
        # registered lingers in /showrepl /errorsonly for ~15 min until KCC's
        # next scheduled run.
        echo "[sconfig] forcing KCC on $target_dc to clear stale 8524..."
        samba-tool drs kcc "$target_dc" \
            -U"${netbios}\\${admin_user}" --password="$admin_pass" 2>&1 \
            | sed 's/^/[kcc] /' || true
        return 0
    fi
    # zone missing is the common cause on unconfigured labs — explain clearly
    if grep -qiE "DNS_ERROR_ZONE_DOES_NOT_EXIST|WERR_DNS_ERROR_ZONE_DOES_NOT_EXIST" <<< "$out"; then
        echo "[sconfig] WARN: reverse zone $reverse_zone does not exist on $target_dc"
        echo "[sconfig]       Windows replication FROM this DC will fail (error 8524) until"
        echo "[sconfig]       the forest admin creates the zone. Continuing anyway."
        return 1
    fi
    echo "[sconfig] WARN: PTR registration failed:"
    echo "$out" | sed 's/^/[ptr] /'
    return 1
}

domain_provision_new() {
    local DC_REALM DC_NETBIOS DC_ADMIN_USER DC_ADMIN_PASS DC_DNS_FORWARDER
    collect_domain_info || return
    collect_new_admin_password || return

    yesno "Provision NEW forest?\n\nRealm: $DC_REALM\nNetBIOS: $DC_NETBIOS\nDNS: SAMBA_INTERNAL\nForwarder: $DC_DNS_FORWARDER" || return

    rm -f /etc/samba/smb.conf
    systemctl stop samba-ad-dc 2>/dev/null || true
    write_krb5_conf "$DC_REALM"

    {
        echo "10"; echo "XXX"; echo "Provisioning AD domain..."; echo "XXX"
        samba-tool domain provision \
            --realm="$DC_REALM" --domain="$DC_NETBIOS" \
            --server-role=dc --dns-backend=SAMBA_INTERNAL \
            --adminpass="$DC_ADMIN_PASS" \
            --option="dns forwarder = $DC_DNS_FORWARDER" 2>&1 | tail -5
        echo "50"; echo "XXX"; echo "Applying hardening..."; echo "XXX"
        apply_hardening_to_smb_conf
        echo "70"; echo "XXX"; echo "Starting services..."; echo "XXX"
        post_provision_setup "$DC_REALM" "$DC_DNS_FORWARDER"
        echo "100"; echo "XXX"; echo "Done!"; echo "XXX"
    } | whiptail --title "Provisioning" --gauge "Starting..." 8 60 0

    if is_addc_running; then
        info "Domain provisioned!\n\nRealm: $DC_REALM | NetBIOS: $DC_NETBIOS\n\nNext: Run Diagnostics (6), Post-Domain Setup (3), Hardening (5)"
    else
        info "WARNING: samba-ad-dc not running.\n\nCheck: journalctl -u samba-ad-dc -n 50"
    fi
}

domain_join_dc() {
    local DC_REALM DC_NETBIOS DC_ADMIN_USER DC_ADMIN_PASS DC_DNS_FORWARDER
    collect_domain_info || return

    local existing_dc
    existing_dc=$(whiptail --inputbox "FQDN or IP of existing DC to replicate from:" \
        10 64 "" 3>&1 1>&2 2>&3) || return

    local dc_ip
    if ! dc_ip=$(resolve_dc_ip "$existing_dc"); then
        info "Cannot resolve '$existing_dc' via the current resolver.\nProvide an IP or fix /etc/resolv.conf first."
        return
    fi

    collect_join_credentials || return

    yesno "Join as ADDITIONAL DC?\n\nRealm: $DC_REALM\nSource DC: $existing_dc ($dc_ip)\nAs: ${DC_NETBIOS}\\\\${DC_ADMIN_USER}" || return

    # Auto-detect target forest functional level. Samba's default
    # `ad dc functional level = 2008_R2` silently fails against any
    # 2012+ forest with WERR_DS_INCOMPATIBLE_VERSION.
    local fl_str
    fl_str=$(probe_forest_fl "$dc_ip")

    rm -f /etc/samba/smb.conf
    systemctl stop samba-ad-dc 2>/dev/null || true
    write_krb5_conf "$DC_REALM"
    take_over_resolv_conf
    echo -e "search ${DC_REALM,,}\nnameserver ${dc_ip}" > /etc/resolv.conf

    whiptail --infobox "Joining domain at FL=$fl_str... This may take several minutes." 8 60

    if samba-tool domain join "$DC_REALM" DC \
        --dns-backend=SAMBA_INTERNAL \
        --option="dns forwarder = $DC_DNS_FORWARDER" \
        --option="ad dc functional level = $fl_str" \
        -U"${DC_NETBIOS}\\${DC_ADMIN_USER}" \
        --password="$DC_ADMIN_PASS" 2>&1 | tail -20; then
        apply_hardening_to_smb_conf
        post_provision_setup "$DC_REALM" "$DC_DNS_FORWARDER"
        register_own_ptr "$dc_ip" "$DC_NETBIOS" "$DC_ADMIN_USER" "$DC_ADMIN_PASS" "$DC_REALM" || true
        seed_sysvol "$dc_ip" "$DC_NETBIOS" "$DC_ADMIN_USER" "$DC_ADMIN_PASS" "$DC_REALM" || true
        configure_chrony_for_domain "$dc_ip"
        _generate_tls_cert_core
        info "Joined as additional DC (FL=$fl_str)!\nRealm: $DC_REALM"
    else
        info "Join FAILED.\n\nCheck connectivity to $existing_dc ($dc_ip) and credentials."
    fi
}

domain_join_rodc() {
    local DC_REALM DC_NETBIOS DC_ADMIN_USER DC_ADMIN_PASS DC_DNS_FORWARDER
    collect_domain_info || return

    local existing_dc
    existing_dc=$(whiptail --inputbox "FQDN or IP of writable DC:" \
        10 64 "" 3>&1 1>&2 2>&3) || return

    local dc_ip
    if ! dc_ip=$(resolve_dc_ip "$existing_dc"); then
        info "Cannot resolve '$existing_dc' via the current resolver.\nProvide an IP or fix /etc/resolv.conf first."
        return
    fi

    collect_join_credentials || return

    yesno "Join as RODC?\n\nRealm: $DC_REALM\nSource DC: $existing_dc ($dc_ip)\nAs: ${DC_NETBIOS}\\\\${DC_ADMIN_USER}" || return

    local fl_str
    fl_str=$(probe_forest_fl "$dc_ip")

    rm -f /etc/samba/smb.conf
    systemctl stop samba-ad-dc 2>/dev/null || true
    write_krb5_conf "$DC_REALM"
    take_over_resolv_conf
    echo -e "search ${DC_REALM,,}\nnameserver ${dc_ip}" > /etc/resolv.conf

    whiptail --infobox "Joining as RODC at FL=$fl_str..." 8 60

    if samba-tool domain join "$DC_REALM" RODC \
        --dns-backend=SAMBA_INTERNAL \
        --option="dns forwarder = $DC_DNS_FORWARDER" \
        --option="ad dc functional level = $fl_str" \
        -U"${DC_NETBIOS}\\${DC_ADMIN_USER}" \
        --password="$DC_ADMIN_PASS" 2>&1 | tail -20; then
        apply_hardening_to_smb_conf
        post_provision_setup "$DC_REALM" "$DC_DNS_FORWARDER"
        register_own_ptr "$dc_ip" "$DC_NETBIOS" "$DC_ADMIN_USER" "$DC_ADMIN_PASS" "$DC_REALM" || true
        seed_sysvol "$dc_ip" "$DC_NETBIOS" "$DC_ADMIN_USER" "$DC_ADMIN_PASS" "$DC_REALM" || true
        configure_chrony_for_domain "$dc_ip"
        _generate_tls_cert_core
        info "Joined as RODC (FL=$fl_str)!\nRealm: $DC_REALM"
    else
        info "RODC join FAILED."
    fi
}

#===============================================================================
# 3. POST-DOMAIN SETUP
#===============================================================================
menu_post_domain() {
    is_provisioned || { info "Not provisioned yet. Use Domain Operations (2) first."; return; }

    while true; do
        local choice
        choice=$(whiptail --title "Post-Domain Setup" \
            --menu "Configure services after domain provisioning." \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Enable Domain Logins (winbind + NSS + PAM)" \
            "2" "Grant sudo to Domain Admins" \
            "3" "Configure NTP (Chrony) for AD" \
            "4" "Reset Administrator Password" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) setup_domain_logins ;;
            2) setup_domain_sudo ;;
            3) setup_chrony ;;
            4) reset_admin_password ;;
            B|b) return ;;
        esac
    done
}

setup_domain_logins() {
    yesno "Enable AD domain account logins via SSH?\n\nThis adds winbind to NSS, configures PAM mkhomedir,\nand sets default shell to /bin/bash." || return

    local nss="/etc/nsswitch.conf"
    cp "$nss" "${nss}.bak-$(date +%s)"

    if ! grep -q 'winbind' "$nss"; then
        sed -i 's/^passwd:\s*.*/passwd:         files winbind/' "$nss"
        sed -i 's/^group:\s*.*/group:          files winbind/' "$nss"
    fi

    pam-auth-update --enable mkhomedir 2>/dev/null || {
        grep -q 'pam_mkhomedir' /etc/pam.d/common-session 2>/dev/null || \
            echo "session required pam_mkhomedir.so skel=/etc/skel umask=0022" >> /etc/pam.d/common-session
    }

    local smb="/etc/samba/smb.conf"
    if ! grep -q 'template homedir' "$smb" 2>/dev/null; then
        sed -i '/\[global\]/a\\n        template homedir = /home/%U\n        template shell = /bin/bash' "$smb"
    fi

    systemctl restart samba-ad-dc
    sleep 2

    local test_output
    test_output=$(wbinfo -u 2>&1 | head -5)
    info "Domain logins configured.\n\nwbinfo -u:\n${test_output}\n\nSSH: ssh DOMAIN\\\\user@server"
}

setup_domain_sudo() {
    local netbios
    netbios=$(get_netbios)
    [[ "$netbios" == "(not provisioned)" ]] && { info "Not provisioned."; return; }

    local sudo_group
    sudo_group=$(whiptail --inputbox "Domain group to grant sudo:" \
        10 64 "Domain Admins" 3>&1 1>&2 2>&3) || return

    local sudoers_file="/etc/sudoers.d/domain-admins"
    cat > "$sudoers_file" << SUDOEOF
%${netbios}\\\\${sudo_group}  ALL=(ALL:ALL) ALL
SUDOEOF
    chmod 440 "$sudoers_file"

    if visudo -cf "$sudoers_file" &>/dev/null; then
        info "Sudo granted to '${netbios}\\${sudo_group}'."
    else
        rm -f "$sudoers_file"
        info "ERROR: Syntax validation failed. Entry removed."
    fi
}

setup_chrony() {
    local subnet
    subnet=$(whiptail --inputbox "Network subnet for NTP clients (e.g., 192.168.1.0/24):" \
        10 64 "192.168.1.0/24" 3>&1 1>&2 2>&3) || return

    cat > /etc/chrony/chrony.conf << CHRONEOF
server time.cloudflare.com iburst
server time.google.com iburst
pool 2.debian.pool.ntp.org iburst
driftfile /var/lib/chrony/drift
allow ${subnet}
ntpsigndsocket /var/lib/samba/ntp_signd
makestep 1.0 3
CHRONEOF

    mkdir -p /var/lib/samba/ntp_signd
    chown root:_chrony /var/lib/samba/ntp_signd 2>/dev/null || \
    chown root:chrony /var/lib/samba/ntp_signd 2>/dev/null || true
    chmod 750 /var/lib/samba/ntp_signd

    systemctl enable chrony
    systemctl restart chrony
    info "Chrony configured.\nClients allowed from: $subnet\nNTP signing enabled."
}

reset_admin_password() {
    local new_pass confirm_pass
    new_pass=$(whiptail --passwordbox "New Administrator password:" 10 64 3>&1 1>&2 2>&3) || return
    confirm_pass=$(whiptail --passwordbox "Confirm:" 10 64 3>&1 1>&2 2>&3) || return
    [[ "$new_pass" != "$confirm_pass" ]] && { info "Passwords don't match."; return; }

    if samba-tool user setpassword administrator --newpassword="$new_pass" 2>&1; then
        info "Password updated."
    else
        info "ERROR: Check complexity requirements."
    fi
}

#===============================================================================
# 4. SYSVOL REPLICATION
#===============================================================================
SYSVOL_SYNC_CONF="/etc/samba/sysvol-sync.conf"
SYSVOL_SYNC_CRON="/etc/cron.d/sysvol-sync"
SYSVOL_SYNC_OLD_CRED="/etc/samba/sysvol-sync.cred"

menu_sysvol_sync() {
    is_provisioned || { info "Not provisioned."; return; }

    while true; do
        local choice
        choice=$(whiptail --title "SYSVOL Replication" \
            --menu "Samba has no DFSR. This menu sets up the periodic puller that\nfetches SYSVOL changes from any reachable DC, preferring Windows.\nAuthentication uses this DC's own machine credentials (smbclient -P)." \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Configure SYSVOL Sync" \
            "2" "Run Sync Now" \
            "3" "Show SYSVOL Freshness (per-GPO version table)" \
            "4" "Show Sync Status" \
            "5" "Reset SYSVOL ACLs" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) configure_sysvol_sync ;;
            2) run_sysvol_sync ;;
            3) show_sysvol_freshness ;;
            4) show_sync_status ;;
            5) reset_sysvol_acls ;;
            B|b) return ;;
        esac
    done
}

# Migrate legacy sysvol-sync.conf written by an older samba-sconfig (the
# transport=ssh|smb era) to the v2 format. Idempotent. Drops the credentials
# file (it held a Domain Admin password — no longer needed under machine
# Kerberos auth) and the SSH key reference (the new sync uses SMB-only).
_migrate_old_sysvol_conf() {
    [[ -f "$SYSVOL_SYNC_CONF" ]] || return 0
    grep -qE '^(SYNC_TRANSPORT|REMOTE_DC|SMB_CRED_FILE|SSH_KEY)=' "$SYSVOL_SYNC_CONF" 2>/dev/null || return 0

    info "Detected legacy sysvol-sync.conf. Migrating to machine-Kerberos format and removing the old credentials file (if present)."
    if [[ -f "$SYSVOL_SYNC_OLD_CRED" ]]; then
        shred -u "$SYSVOL_SYNC_OLD_CRED" 2>/dev/null || rm -f "$SYSVOL_SYNC_OLD_CRED"
    fi
    rm -f "$SYSVOL_SYNC_CONF"
}

configure_sysvol_sync() {
    _migrate_old_sysvol_conf

    local interval
    interval=$(whiptail --inputbox \
        "Sync interval (minutes, 1-59).\n\n15 is a good default: cheap when nothing changed, responsive enough\nfor production GPO edits, low log churn." \
        13 68 "15" 3>&1 1>&2 2>&3) || return
    [[ "$interval" =~ ^[0-9]+$ ]] || { info "Interval must be a positive integer."; return; }
    (( interval >= 1 && interval <= 59 )) || { info "Interval must be between 1 and 59 minutes."; return; }

    local preferred excluded
    preferred=$(whiptail --inputbox \
        "Optional: space-separated FQDNs to try BEFORE the normal Windows-first ranking. Leave blank to use the default tier order (Windows DCs first, Samba peers second)." \
        13 72 "" 3>&1 1>&2 2>&3) || return
    excluded=$(whiptail --inputbox \
        "Optional: space-separated FQDNs that must NEVER be used as a SYSVOL source (e.g. a half-decommissioned DC). Blank = no exclusions." \
        13 72 "" 3>&1 1>&2 2>&3) || return

    if [[ ! -f /var/lib/samba/private/secrets.tdb ]]; then
        info "DC not joined / provisioned (no secrets.tdb). Configure aborted."
        return
    fi

    umask 077
    cat > "$SYSVOL_SYNC_CONF" <<SCEOF
# sysvol-sync.conf — v2 (multi-source, machine-credentials)
# Managed by samba-sconfig. Hand-edits survive next configure if format is preserved.
SYNC_INTERVAL="${interval}"
PREFERRED_DCS="${preferred}"
EXCLUDE_DCS="${excluded}"
SCEOF
    chmod 640 "$SYSVOL_SYNC_CONF"
    umask 022

    cat > "$SYSVOL_SYNC_CRON" <<CRON
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/${interval} * * * * root /usr/local/sbin/sysvol-sync
CRON
    chmod 644 "$SYSVOL_SYNC_CRON"

    info "Configured.\nInterval: ${interval} min | Preferred: ${preferred:-<none>} | Excluded: ${excluded:-<none>}\n\nNext: 'Run Sync Now' (menu 2) to do an immediate cycle, then\n'Show SYSVOL Freshness' (menu 3) to confirm GPOs converged."
}

run_sysvol_sync() {
    [[ -f "$SYSVOL_SYNC_CONF" ]] || { info "Not configured. Run Configure (menu 1) first."; return; }
    yesno "Run SYSVOL sync now?" || return
    whiptail --infobox "Syncing..." 6 40
    local output; output=$(/usr/local/sbin/sysvol-sync 2>&1)
    info "Run complete. Log: /var/log/samba/sysvol-sync.log\n\n$(echo "$output" | tail -8)"
}

show_sysvol_freshness() {
    [[ -x /usr/local/sbin/sysvol-sync ]] || { info "sysvol-sync helper missing. Re-run prepare-image.sh."; return; }
    local output; output=$(/usr/local/sbin/sysvol-sync --status 2>&1)
    whiptail --title "SYSVOL Freshness" --scrolltext --msgbox "$output" 24 96
}

reset_sysvol_acls() {
    yesno "Reset SYSVOL ACLs?" || return
    # Older deployments provisioned/joined before the idmap-config fix will
    # loop here forever with "idmap range not specified for domain '*'".
    # Calling ensure_idmap_config is idempotent and cheap.
    ensure_idmap_config
    local output; output=$(samba-tool ntacl sysvolreset 2>&1)
    info "ACLs reset.\n${output}"
}

show_sync_status() {
    local st="SYSVOL Sync Status\n==================\n\n"
    if [[ -f "$SYSVOL_SYNC_CONF" ]]; then
        # shellcheck disable=SC1091
        source "$SYSVOL_SYNC_CONF"
        st+="Interval:   ${SYNC_INTERVAL:-?} min\n"
        st+="Preferred:  ${PREFERRED_DCS:-<none>}\n"
        st+="Excluded:   ${EXCLUDE_DCS:-<none>}\n\n"
    else
        st+="Not configured.\n\n"
    fi
    [[ -f "$SYSVOL_SYNC_CRON" ]] && st+="Cron:\n$(cat "$SYSVOL_SYNC_CRON")\n\n" || st+="Cron: not installed\n\n"
    [[ -f /var/log/samba/sysvol-sync.log ]] && st+="Last 12 log lines:\n$(tail -12 /var/log/samba/sysvol-sync.log)\n" || st+="No sync log yet.\n"
    whiptail --title "Sync Status" --scrolltext --msgbox "$st" 24 88
}

#===============================================================================
# 4b. DFS NAMESPACE
#
# Tertiary domain-based DFS-N namespace server. The Windows-side admin
# adds this DC as a low-priority namespace root target; this code reads
# the (replicated) AD link metadata and materializes it as MSDFS symlinks
# under a Samba-hosted share.
#
# Design rationale and threat model live in docs/DFS-N.md. The short
# version: AD content is not blindly trusted because we run as root and
# create filesystem entries from it; pruning is gated to never delete
# anything the tool didn't create; the Python helper does the binary
# blob parse because msDFS-TargetListv2 is not a CSV.
#===============================================================================
readonly DFS_DEFAULT_ROOT="/srv/samba/dfs_root"
readonly DFS_DEFAULT_SHARE="dfs_root"
readonly DFS_INCLUDE_FILE="/etc/samba/conf.d/dfs-root.conf"
readonly DFS_SENTINEL_NAME=".dfsn-managed"
readonly DFS_LOCK="/run/samba-dfs-update.lock"
readonly DFS_CONF="/etc/samba/dfs-update.conf"
readonly DFS_PARSE_HELPER="/usr/local/sbin/samba-dfs-parse-targets"
readonly DFS_UNIT="/etc/systemd/system/samba-dfs-update.service"
readonly DFS_TIMER="/etc/systemd/system/samba-dfs-update.timer"
readonly DFS_LOG="/var/log/samba/dfs-update.log"

# Convert a dotted realm (lab.test) to a comma-joined base DN (DC=lab,DC=test).
# Lower-cased on output. Returns 1 if smb.conf has no realm.
_dfs_get_base_dn() {
    local realm
    realm=$(grep -oP '^[[:space:]]*realm[[:space:]]*=[[:space:]]*\K.*' \
                /etc/samba/smb.conf 2>/dev/null | head -1 | tr A-Z a-z | tr -d '[:space:]\r')
    [[ -z "$realm" ]] && return 1
    local IFS=. parts=()
    read -r -a parts <<< "$realm"
    local dn="" p
    for p in "${parts[@]}"; do dn+="DC=${p},"; done
    printf '%s' "${dn%,}"
}

# Validate a single AD-sourced msDFS-LinkPathv2 component-by-component.
# Output (on success): the relative POSIX path with the AD's leading slash
# stripped. Real Windows-stored paths look like "/Reports" or
# "/Sub/Folder" with FORWARD-slash separators (confirmed against a live
# WS2025 namespace; what MS-DFSNM v1 documents differs).
#
# Rejection rules (each one paid for in security review): no controls, no
# embedded backslashes (would smuggle a Windows path component), no
# `..`/`.`/empty components, no Windows-reserved-in-NTFS chars, strict
# length cap.
_dfs_normalize_link_path() {
    local raw="$1"
    [[ -z "$raw" ]] && return 1
    [[ "$raw" =~ [[:cntrl:]] ]] && return 1
    # Backslash inside the path is a red flag — Windows uses backslash on
    # the wire but stores forward slash in this attribute. A backslash here
    # is either a malformed entry (raw-LDAP injection) or a traversal
    # attempt; reject either way.
    [[ "$raw" == *\\* ]] && return 1
    # AD always carries a leading slash; strip it so we get a clean relative
    # path. Reject anything that doesn't have it (defensive: real Windows
    # always writes the slash).
    [[ "$raw" != /* ]] && return 1
    local rel="${raw#/}"
    [[ -z "$rel" ]] && return 1
    (( ${#rel} > 200 )) && return 1
    # Per-component validation
    local IFS=/ parts=() c
    read -r -a parts <<< "$rel"
    (( ${#parts[@]} == 0 )) && return 1
    for c in "${parts[@]}"; do
        [[ -z "$c" || "$c" == "." || "$c" == ".." ]] && return 1
        # Reject the NTFS-reserved character set and the colon (which
        # could be used to fake a stream/UNC suffix).
        [[ "$c" == *[\\/:*?\"\<\>\|]* ]] && return 1
    done
    printf '%s' "$rel"
}

# Validate a parsed UNC target. Returns 0 if it looks safe to embed in a
# comma-joined msdfs symlink target string. The actual validation lives
# in appliance-core's identity.sh (appcore_id_unc_validate); this thin
# wrapper preserves the function name local code already calls and
# falls back to the inline rules when the lib isn't vendored (older
# image, broken build).
_dfs_validate_target_unc() {
    local unc="$1"
    if command -v appcore_id_unc_validate >/dev/null 2>&1; then
        appcore_id_unc_validate "$unc"
        return
    fi
    # Fallback (kept terse): reject anything that could corrupt the
    # comma-joined target list or smuggle additional backslashes.
    local rest server share
    [[ "$unc" == \\\\* ]] || return 1
    rest="${unc#\\\\}"
    server="${rest%%\\*}"
    [[ "$server" == "$rest" ]] && return 1
    share="${rest#*\\}"
    [[ -z "$server" || -z "$share" ]] && return 1
    [[ "$server" =~ ^[A-Za-z0-9._-]{1,63}$ ]] || return 1
    (( ${#share} >= 1 && ${#share} <= 80 )) || return 1
    [[ "$share" == *","* || "$share" == *"\\"* ]] && return 1
    [[ "$share" =~ ^[A-Za-z0-9._\$\ \&\(\)-]+$ ]] || return 1
    return 0
}

# ldbsearch wraps long lines in LDIF. Unwrap so callers can grep -E reliably.
# Continuation lines start with a single space.
_dfs_unwrap_ldif() {
    awk '
        /^[^ ]/ { if (prev != "") print prev; prev = $0; next }
        /^ /    { prev = prev substr($0, 2); next }
        END     { if (prev != "") print prev }
    '
}

# Render a base64-encoded msDFS-TargetListv2 blob into TSV records via
# the Python helper. Each line:
#   priorityClass\tpriorityRank\tstate\tunc
# Helper exits non-zero on parse failure (handled below).
_dfs_render_targets() {
    local blob_b64="$1"
    [[ -x "$DFS_PARSE_HELPER" ]] || { echo "[dfs] parse helper missing: $DFS_PARSE_HELPER" >&2; return 1; }
    printf '%s' "$blob_b64" | "$DFS_PARSE_HELPER"
}

# Order targets first by AD-sourced priorityClass (DFS-N convention:
# globalHigh, siteCostHigh, siteCostNormal, siteCostLow, globalLow), then
# move SC_DFS_PREFER-regex matches to the front of each priority bucket.
# Operator-supplied prefer thus refines AD priority; it can't override it
# (which would defeat the point of the Windows-side priority configuration).
#
# Input on stdin: TSV records as emitted by the helper.
# Output on stdout: one UNC per line, in chosen order.
_dfs_order_targets() {
    local prefer="${1:-}"
    local -a recs=()
    local rec
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        recs+=("$rec")
    done
    # AWK does the multi-key sort: numeric class rank, then prefer match,
    # then preserve original order via line number. Bash 3.2 doesn't have
    # multi-key sort; awk is everywhere and keeps the logic readable.
    printf '%s\n' "${recs[@]}" | awk -F'\t' -v prefer="$prefer" '
        BEGIN {
            cls["globalHigh"]=0; cls["siteCostHigh"]=1; cls["siteCostNormal"]=2;
            cls["siteCostLow"]=3; cls["globalLow"]=4; cls["manual"]=5
        }
        {
            c = (($1 in cls) ? cls[$1] : 9)
            p = (prefer != "" && $4 ~ prefer) ? 0 : 1
            printf "%d\t%d\t%06d\t%s\n", c, p, NR, $4
        }
    ' | sort -t $'\t' -k1,1n -k2,2n -k3,3n | awk -F'\t' '{print $4}'
}

# Atomic-swap a msdfs symlink. Caller passes the full literal symlink target
# (e.g. "msdfs:srv1\share,srv2\share"). Idempotent: if the existing symlink
# already has this target, no-op.
_dfs_write_symlink() {
    local link_path="$1" target="$2"
    if [[ -L "$link_path" ]]; then
        local cur
        cur=$(readlink "$link_path" 2>/dev/null || true)
        [[ "$cur" == "$target" ]] && return 0
    fi
    local tmp="${link_path}.tmp.$$"
    rm -f "$tmp"
    ln -s "$target" "$tmp" || return 1
    mv -T "$tmp" "$link_path"
}

# Walk the namespace dir and remove only entries we own: symlinks whose
# target begins with "msdfs:" AND whose POSIX path is not in the
# authoritative-set file ($1). Anything else (regular files, foreign
# symlinks, non-empty directories) is logged and left alone. After unlinks,
# rmdir empty descendant directories bottom-up.
_dfs_prune() {
    local ns_root="$1" keep_file="$2"
    local link rel
    while IFS= read -r -d '' link; do
        rel="${link#$ns_root/}"
        if grep -Fxq "$rel" "$keep_file"; then continue; fi
        local tgt
        tgt=$(readlink "$link" 2>/dev/null || true)
        if [[ "$tgt" == msdfs:* ]]; then
            echo "[dfs] prune symlink: $rel" >&2
            rm -f "$link"
        else
            echo "[dfs] WARN foreign symlink left in place: $rel -> $tgt" >&2
        fi
    done < <(find "$ns_root" -mindepth 1 -type l -print0)

    # Empty-dir prune, bottom-up. Stops at $ns_root.
    find "$ns_root" -mindepth 1 -depth -type d -empty -print0 \
        | xargs -0 -r rmdir 2>/dev/null || true
}

# Idempotently install the smb.conf drop-in for the namespace share.
# Note: read only = yes is intentional. Clients are referred to targets;
# they never write to the namespace root itself. Privileged writes happen
# locally as root.
_dfs_write_drop_in() {
    local root_path="$1" share="$2"
    install -d -m 0755 /etc/samba/conf.d
    cat > "$DFS_INCLUDE_FILE" <<DROPEOF
# Managed by samba-sconfig dfs-init. Edits will be overwritten.
[${share}]
    path = ${root_path}
    msdfs root = yes
    read only = yes
    guest ok = no
    vfs objects = acl_xattr
DROPEOF
    chmod 0644 "$DFS_INCLUDE_FILE"

    local smb=/etc/samba/smb.conf
    if ! grep -qF "include = $DFS_INCLUDE_FILE" "$smb" 2>/dev/null; then
        # Insert INTO [global], not at EOF. The post-provision smb.conf
        # ends with [sysvol]/[netlogon], so an EOF append lands inside
        # the last service section. Samba still parses the include's
        # own [dfs_root] section header, but testparm reports the
        # include line as a service parameter — confusing and brittle.
        # Mirrors the technique in apply_hardening_to_smb_conf.
        local tmp
        tmp=$(mktemp)
        awk -v inc="$DFS_INCLUDE_FILE" '
            BEGIN { inserted = 0 }
            /^\[global\][[:space:]]*$/ && !inserted {
                print
                print "\t# Added by samba-sconfig dfs-init"
                print "\tinclude = " inc
                inserted = 1
                next
            }
            { print }
        ' "$smb" > "$tmp"
        cat "$tmp" > "$smb"
        rm -f "$tmp"
    fi

    # host msdfs is on by default in modern Samba; assert defensively.
    if ! testparm -s --parameter-name='host msdfs' 2>/dev/null | grep -qi '^Yes'; then
        if ! grep -qE '^[[:space:]]*host msdfs[[:space:]]*=' "$smb"; then
            sed -i '/^\[global\]/a\        host msdfs = yes' "$smb"
        fi
    fi
}

_dfs_remove_drop_in() {
    rm -f "$DFS_INCLUDE_FILE"
    # Match the indented (\t-prefixed) form inserted by _dfs_write_drop_in.
    sed -i '/^\t# Added by samba-sconfig dfs-init$/{N;/include = \/etc\/samba\/conf.d\/dfs-root.conf/d}' \
        /etc/samba/smb.conf 2>/dev/null || true
}

# Install systemd unit + timer. Service runs as root because it writes
# under the namespace root and reads sam.ldb. Hardening below removes
# everything we don't need.
_dfs_install_units() {
    local interval="$1"
    cat > "$DFS_UNIT" <<UNITEOF
[Unit]
Description=Samba DFS-N namespace symlink updater
After=samba-ad-dc.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/samba-sconfig dfs-update
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
PrivateTmp=yes
ReadWritePaths=${DFS_DEFAULT_ROOT} /run /var/log/samba
ReadOnlyPaths=/var/lib/samba
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=yes
MemoryDenyWriteExecute=yes
UNITEOF
    cat > "$DFS_TIMER" <<TIMEREOF
[Unit]
Description=Periodic Samba DFS-N namespace sync

[Timer]
OnBootSec=2min
OnUnitActiveSec=${interval}
RandomizedDelaySec=2min
Persistent=true
Unit=samba-dfs-update.service

[Install]
WantedBy=timers.target
TIMEREOF
    systemctl daemon-reload
    systemctl enable --now samba-dfs-update.timer
}

_dfs_remove_units() {
    systemctl disable --now samba-dfs-update.timer 2>/dev/null || true
    rm -f "$DFS_UNIT" "$DFS_TIMER"
    systemctl daemon-reload
}

# The headless update entry point. Read config, take lock, walk namespaces.
_dfs_run_update() {
    local dry="${SC_DFS_DRY_RUN:-0}"

    [[ -f "$DFS_CONF" ]] || { echo "[dfs] no config — run dfs-init first" >&2; return 1; }
    # shellcheck disable=SC1090
    source "$DFS_CONF"
    : "${DFS_NAMESPACES:=}"
    : "${DFS_PREFER:=}"
    : "${DFS_ROOT:=$DFS_DEFAULT_ROOT}"
    [[ -z "$DFS_NAMESPACES" ]] && { echo "[dfs] DFS_NAMESPACES empty — nothing to do" >&2; return 0; }
    [[ -f "${DFS_ROOT}/${DFS_SENTINEL_NAME}" ]] || {
        echo "[dfs] sentinel ${DFS_SENTINEL_NAME} missing under ${DFS_ROOT} — refusing to operate" >&2
        return 2
    }

    local base_dn
    base_dn=$(_dfs_get_base_dn) || { echo "[dfs] could not derive base DN" >&2; return 1; }

    # Take the lock. flock returns 1 on contention; we exit 0 silently because
    # a missed run is harmless — the next timer tick picks up.
    exec 9>"$DFS_LOCK" || { echo "[dfs] cannot open lock $DFS_LOCK" >&2; return 1; }
    if ! flock -n 9; then
        echo "[dfs] another update is in progress; exiting" >&2
        return 0
    fi

    mkdir -p "$(dirname "$DFS_LOG")"
    {
        echo "=== $(date -Is) update begin (namespaces: $DFS_NAMESPACES) ==="
    } >> "$DFS_LOG"

    local ns rc=0
    for ns in $DFS_NAMESPACES; do
        _dfs_update_one_namespace "$ns" "$base_dn" "$dry" || rc=$?
    done

    if [[ "$dry" != "1" ]]; then
        smbcontrol all reload-config 2>/dev/null || true
    fi

    {
        echo "=== $(date -Is) update end (rc=$rc) ==="
    } >> "$DFS_LOG"
    return "$rc"
}

# Core per-namespace pass. Three guards:
#  - empty result: warn, leave filesystem alone, do not prune.
#  - sentinel missing on the per-NS dir: refuse to operate on that NS.
#  - prune scope: only msdfs:* symlinks under the per-NS subtree, never
#    files we don't own.
_dfs_update_one_namespace() {
    local ns="$1" base_dn="$2" dry="$3"
    local ns_root="${DFS_ROOT}/${ns}"

    # Per-NS sentinel mirrors the global one; protects against
    # accidentally pointing at an unrelated directory.
    if [[ ! -d "$ns_root" || ! -f "${ns_root}/${DFS_SENTINEL_NAME}" ]]; then
        echo "[dfs/${ns}] per-namespace dir or sentinel missing — skipping" >&2
        return 1
    fi

    # AD layout (confirmed against a live WS2025 forest, NOT what the
    # MS-DFSNM v1 doc suggests):
    #   CN=<NS>,CN=Dfs-Configuration,CN=System,<dn>           ← namespace anchor
    #     └── CN=<NS>,CN=<NS>,CN=Dfs-Configuration,...        ← link container
    #           └── CN=link-<guid>,...                        ← msDFS-Linkv2
    # Note "Dfs-Configuration" (no "n"), the doubled namespace component,
    # and the link-<guid> RDN.
    local search_base="CN=${ns},CN=${ns},CN=Dfs-Configuration,CN=System,${base_dn}"
    local raw
    raw=$(ldbsearch -H /var/lib/samba/private/sam.ldb -b "$search_base" -s sub \
            '(objectClass=msDFS-Linkv2)' msDFS-LinkPathv2 msDFS-TargetListv2 2>&1) || {
        echo "[dfs/${ns}] ldbsearch failed:" >&2
        echo "$raw" | head -3 >&2
        return 1
    }

    # Unwrap LDIF continuation lines first.
    local unwrapped
    unwrapped=$(printf '%s\n' "$raw" | _dfs_unwrap_ldif)

    # Empty-result guard: if we see no link-path attributes at all, refuse to
    # prune. An empty namespace is valid; we just exit without changes.
    local link_count
    link_count=$(grep -c '^msDFS-LinkPathv2: ' <<< "$unwrapped" || true)
    if (( link_count == 0 )); then
        echo "[dfs/${ns}] zero links returned — skipping prune (safety)" >&2
        return 0
    fi

    local keep_file
    keep_file=$(mktemp)
    trap 'rm -f "$keep_file"' RETURN

    # Walk records. LDIF groups attrs of one entry between successive
    # `dn:` lines (or a blank line at the end). We commit the record on
    # those boundaries rather than when we see TargetListv2, so the
    # parser is order-independent — ldb returns attrs alphabetically
    # today but that's not load-bearing.
    local cur_path="" cur_blob=""
    local applied=0 rejected=0
    _flush() {
        if [[ -n "$cur_path" && -n "$cur_blob" ]]; then
            if _dfs_apply_one_link "$ns" "$ns_root" "$cur_path" "$cur_blob" "$keep_file" "$dry"; then
                applied=$((applied+1))
            else
                rejected=$((rejected+1))
            fi
        fi
        cur_path=""; cur_blob=""
    }
    while IFS= read -r line; do
        case "$line" in
          'dn: '*)                  _flush ;;
          '')                       _flush ;;
          'msDFS-LinkPathv2: '*)    cur_path="${line#msDFS-LinkPathv2: }" ;;
          'msDFS-TargetListv2:: '*) cur_blob="${line#msDFS-TargetListv2:: }" ;;
        esac
    done <<< "$unwrapped"
    _flush

    echo "[dfs/${ns}] applied=${applied} rejected=${rejected}" >&2
    {
        echo "$(date -Is) ns=${ns} applied=${applied} rejected=${rejected} dry=${dry}"
    } >> "$DFS_LOG"

    if [[ "$dry" != "1" && "$applied" -gt 0 ]]; then
        _dfs_prune "$ns_root" "$keep_file"
    fi
    return 0
}

# Apply one link record. Validates path + targets, orders, writes the
# symlink atomically, records the kept path in $keep_file.
_dfs_apply_one_link() {
    local ns="$1" ns_root="$2" raw_path="$3" blob_b64="$4" keep_file="$5" dry="$6"
    local rel
    rel=$(_dfs_normalize_link_path "$raw_path") || {
        echo "[dfs/${ns}] reject path: $raw_path" >&2
        return 1
    }

    # The helper emits TSV records: priorityClass\tpriorityRank\tstate\tunc.
    local tsv_records
    tsv_records=$(_dfs_render_targets "$blob_b64") || {
        echo "[dfs/${ns}] target parse failed for: $rel" >&2
        return 1
    }

    # Validate every UNC. One bad target rejects the whole link — partial
    # target lists would silently downgrade the referral. The 4th tab-
    # separated field is the UNC.
    local rec u
    while IFS= read -r rec; do
        [[ -z "$rec" ]] && continue
        u="${rec##*$'\t'}"
        _dfs_validate_target_unc "$u" || {
            echo "[dfs/${ns}] reject target: $u (link $rel)" >&2
            return 1
        }
    done <<< "$tsv_records"

    # Order by AD priority class first, then by prefer regex within each
    # bucket. Output is one UNC per line.
    local ordered
    ordered=$(printf '%s\n' "$tsv_records" | _dfs_order_targets "${DFS_PREFER:-}")

    # Build the symlink target string: "msdfs:srv1\share,srv2\share"
    local joined="" first=1
    while IFS= read -r u; do
        [[ -z "$u" ]] && continue
        u="${u#\\\\}"   # strip leading \\ for msdfs symlink syntax
        if (( first )); then joined+="$u"; first=0; else joined+=",$u"; fi
    done <<< "$ordered"
    [[ -z "$joined" ]] && return 1
    joined="msdfs:${joined}"

    local link_path="${ns_root}/${rel}"
    if [[ "$dry" == "1" ]]; then
        echo "[dfs/${ns}] DRY $rel -> $joined" >&2
    else
        local parent parent_real ns_real
        parent=$(dirname "$link_path")
        # Realpath check BEFORE mkdir. realpath -m resolves symbolically
        # without requiring the path to exist, so we can refuse a
        # containment violation without first creating directories
        # outside the namespace root. This is the second lock; the first
        # is _dfs_normalize_link_path. Both must hold.
        parent_real=$(realpath -m "$parent")
        ns_real=$(realpath -m "$ns_root")
        if [[ "$parent_real" != "$ns_real" && "$parent_real" != "$ns_real"/* ]]; then
            echo "[dfs/${ns}] containment violation: $rel" >&2
            return 1
        fi
        mkdir -p "$parent" || return 1
        _dfs_write_symlink "$link_path" "$joined" || {
            echo "[dfs/${ns}] write failed: $rel" >&2
            return 1
        }
    fi
    printf '%s\n' "$rel" >> "$keep_file"
    return 0
}

#----------------------------- TUI submenu --------------------------------------
menu_dfs() {
    is_provisioned || { info "Not provisioned. Use Domain Operations (2) first."; return; }
    while true; do
        local state="not configured" timer="off" ns="<none>"
        if [[ -f "$DFS_CONF" ]]; then
            state="configured"
            ns=$(awk -F'"' '/^DFS_NAMESPACES=/ {print $2}' "$DFS_CONF" 2>/dev/null)
            [[ -z "$ns" ]] && ns="<none>"
        fi
        systemctl is-active samba-dfs-update.timer &>/dev/null && timer="on"
        local choice
        choice=$(whiptail --title "DFS Namespace Server" \
            --menu "Tertiary domain-based DFS-N namespace server.\nState: ${state}  Timer: ${timer}  Namespaces: ${ns}" \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Initialize namespace server (one-time)" \
            "2" "Configure namespaces and prefer-list" \
            "3" "Run sync now (dry-run)" \
            "4" "Run sync now" \
            "5" "Schedule periodic sync" \
            "6" "Pause / resume timer" \
            "7" "Show DFS-N status" \
            "8" "Remove DFS-N configuration" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) tui_dfs_init ;;
            2) tui_dfs_configure ;;
            3) tui_dfs_run 1 ;;
            4) tui_dfs_run 0 ;;
            5) tui_dfs_schedule ;;
            6) tui_dfs_timer_toggle ;;
            7) tui_dfs_status ;;
            8) tui_dfs_remove ;;
            B|b) return ;;
        esac
    done
}

# Capture sconfig output safely. The earlier `cmd 2>&1 | whiptail msgbox
# "$(cat)"` pattern depends on $(cat) reading the pipeline's stdout, which
# is fragile when whiptail eats stdin on its own side. Capture into a var
# first, then feed whiptail explicitly.
_tui_show() {
    local title="$1" body="$2" h="${3:-20}" w="${4:-78}"
    whiptail --title "$title" --scrolltext --msgbox "$body" "$h" "$w"
}

tui_dfs_init() {
    local share root
    share=$(whiptail --inputbox \
        "DFS-N share name. Clients connect to \\\\<dc>\\<share>.\nMust match: letters/digits, dot, underscore, dash. Default: ${DFS_DEFAULT_SHARE}." \
        12 70 "$DFS_DEFAULT_SHARE" 3>&1 1>&2 2>&3) || return
    [[ "$share" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { info "Invalid share name."; return; }
    root=$(whiptail --inputbox \
        "Filesystem path for the namespace store. Must be absolute.\nDefault: ${DFS_DEFAULT_ROOT}." \
        11 70 "$DFS_DEFAULT_ROOT" 3>&1 1>&2 2>&3) || return
    [[ "$root" = /* ]] || { info "Path must be absolute."; return; }
    local out
    out=$(cli_dfs_init_inner "$share" "$root" 2>&1)
    out+=$'\n\nNext step: pick "Configure namespaces and prefer-list" (menu 2).'
    _tui_show "dfs-init" "$out" 18 78
}

tui_dfs_configure() {
    [[ -f "$DFS_CONF" ]] || { info "Run Initialize (menu 1) first."; return; }
    # shellcheck disable=SC1090
    source "$DFS_CONF"
    local ns prefer
    ns=$(whiptail --inputbox \
        "Namespaces to manage (space-separated, e.g. 'Public Internal').\nEach name: 1-64 chars, letters/digits/dot/underscore/dash." \
        12 72 "${DFS_NAMESPACES:-}" 3>&1 1>&2 2>&3) || return
    prefer=$(whiptail --inputbox \
        "Prefer-regex (extended regex). UNCs matching this are bubbled to the\nfront of each priority bucket. Leave blank to use AD priorityClass only.\nExample: ^\\\\\\\\WIN-" \
        13 72 "${DFS_PREFER:-}" 3>&1 1>&2 2>&3) || return
    # Delegate to the CLI subcommand so name validation is shared.
    local out
    out=$(SC_DFS_PREFER="$prefer" cli_dfs_configure $ns 2>&1) || {
        _tui_show "dfs-configure: rejected" "$out" 14 76
        return
    }
    out+=$'\n\nNext step: "Run sync now (dry-run)" (menu 3) to preview, then\n"Run sync now" (menu 4). Schedule periodic via menu 5.'
    _tui_show "dfs-configure" "$out" 16 78
}

# $1 = 1 for dry-run, 0 for real
tui_dfs_run() {
    [[ -f "$DFS_CONF" ]] || { info "Not configured. Run Initialize + Configure first."; return; }
    local dry="$1" title="DFS sync"
    [[ "$dry" == "1" ]] && title="DFS sync (dry-run)"
    yesno "$title — proceed?" || return
    whiptail --infobox "Running…" 6 40
    local out rc
    if [[ "$dry" == "1" ]]; then
        out=$(SC_DFS_DRY_RUN=1 _dfs_run_update 2>&1); rc=$?
    else
        out=$(_dfs_run_update 2>&1); rc=$?
    fi
    local verdict="OK (rc=$rc)"
    (( rc != 0 )) && verdict="FAILED (rc=$rc)"
    _tui_show "$title — $verdict" "$out" 24 90
}

tui_dfs_schedule() {
    [[ -f "$DFS_CONF" ]] || { info "Not configured. Run Initialize + Configure first."; return; }
    local interval
    interval=$(whiptail --inputbox \
        "Timer interval (systemd time spec, e.g. 15min, 30min, 1h).\nDFS-N config changes slowly; 30min is a good default. Lower\nvalues mean more journal traffic for little practical benefit." \
        13 70 "30min" 3>&1 1>&2 2>&3) || return
    # Loose syntactic check; systemd is the authoritative validator. Catches
    # the most common typo (forgetting the unit suffix).
    [[ "$interval" =~ ^[0-9]+(s|sec|second|seconds|m|min|minute|minutes|h|hr|hour|hours|d|day|days)$ ]] \
        || { info "Interval must be a systemd time spec (e.g. 15min, 1h)."; return; }
    local out
    out=$(cli_dfs_schedule_inner "$interval" 2>&1)
    _tui_show "dfs-schedule" "$out" 18 78
}

tui_dfs_timer_toggle() {
    if systemctl is-active samba-dfs-update.timer &>/dev/null; then
        yesno "Stop the periodic sync timer?\n\n(Configuration is preserved; resume via this menu later.)" || return
        local out; out=$(systemctl stop samba-dfs-update.timer 2>&1)
        _tui_show "Timer paused" "${out:-Timer stopped.}" 10 60
    else
        # Only resume if the unit files actually exist (i.e. schedule was
        # run before). Otherwise nudge the operator to schedule first.
        [[ -f "$DFS_TIMER" ]] || { info "Timer is not installed yet. Use Schedule (menu 5)."; return; }
        yesno "Start the periodic sync timer?" || return
        local out; out=$(systemctl start samba-dfs-update.timer 2>&1)
        _tui_show "Timer resumed" "${out:-Timer started.}" 10 60
    fi
}

tui_dfs_status() {
    local out
    out=$(cli_dfs_status 2>&1)
    _tui_show "DFS-N Status" "$out" 24 90
}

tui_dfs_remove() {
    yesno "Remove DFS-N drop-in, systemd units, and config?\n\nFilesystem under the namespace root is left intact;\nyou can rm -rf it manually if desired." || return
    local out
    out=$(cli_dfs_remove 2>&1)
    _tui_show "dfs-remove" "$out" 14 76
}
menu_hardening() {
    while true; do
        local choice
        choice=$(whiptail --title "Security Hardening" \
            --menu "Harden for production and Windows Server 2025 compatibility." \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Apply SMB/LDAP/Kerberos Hardening (WS2025)" \
            "2" "Enable AD DC Firewall (nftables)" \
            "3" "Disable Firewall" \
            "4" "Generate Self-Signed TLS Certificate" \
            "5" "Show Hardening Status" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) apply_ws2025_hardening ;;
            2) enable_firewall ;;
            3) disable_firewall ;;
            4) generate_tls_cert ;;
            5) show_hardening_status ;;
            B|b) return ;;
        esac
    done
}

apply_ws2025_hardening() {
    is_provisioned || { info "Not provisioned."; return; }
    yesno "Apply WS2025 hardening?\n\n- SMB3 mandatory signing\n- AES-only Kerberos\n- LDAP strong auth\n- NTLMv2 only\n- TLS 1.2+\n\nEnsure all clients support these." || return

    apply_hardening_to_smb_conf
    systemctl restart samba-ad-dc

    is_addc_running && info "Hardening applied and service restarted." || \
        info "WARNING: Service failed. Check journalctl -u samba-ad-dc"
}

enable_firewall() {
    [[ -f /etc/nftables-samba-addc.conf ]] || { info "Ruleset not found. Re-run prepare-image.sh."; return; }
    yesno "Enable AD DC firewall?\nOnly AD ports + SSH will be open." || return

    cp /etc/nftables-samba-addc.conf /etc/nftables.conf
    systemctl enable nftables
    nft -f /etc/nftables.conf
    info "Firewall enabled. Verify: nft list ruleset"
}

disable_firewall() {
    yesno "Disable firewall?" || return
    nft flush ruleset 2>/dev/null || true
    systemctl disable nftables 2>/dev/null || true
    info "Firewall disabled."
}

# Non-TUI core of TLS cert generation. Writes a self-signed cert with SAN
# entries (DNS fqdn, short hostname, IPv4), installs `tls keyfile/certfile/cafile`
# into smb.conf's [global] section, and restarts samba-ad-dc. Called from
# both the TUI menu 5 and automatically after a successful join so the
# appliance never advertises Samba's SAN-less auto-generated cert to clients.
_generate_tls_cert_core() {
    local realm fqdn shortname ip cert_dir
    realm=$(get_realm)
    fqdn=$(get_fqdn 2>/dev/null)
    shortname=$(hostname -s)
    # fallback compose if hostname -f is unreliable post-join
    if [[ "$fqdn" == "(not set)" || -z "$fqdn" || "$fqdn" == "$shortname" ]]; then
        fqdn="${shortname}.${realm,,}"
    fi
    ip=$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    cert_dir="/var/lib/samba/private/tls"
    mkdir -p "$cert_dir"

    echo "[sconfig] generating TLS cert (CN=${fqdn}, SAN=DNS:${fqdn},DNS:${shortname},IP:${ip})"
    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" \
        -subj "/CN=${fqdn}/O=${realm}" \
        -addext "subjectAltName=DNS:${fqdn},DNS:${shortname},IP:${ip}" \
        -addext "basicConstraints=CA:FALSE" \
        -addext "keyUsage=digitalSignature,keyEncipherment" \
        -addext "extendedKeyUsage=serverAuth,clientAuth" \
        2>/dev/null

    cp "$cert_dir/cert.pem" "$cert_dir/ca.pem"
    chmod 600 "$cert_dir/key.pem"
    chmod 644 "$cert_dir/cert.pem" "$cert_dir/ca.pem"

    local smb="/etc/samba/smb.conf"
    if ! grep -q 'tls keyfile' "$smb" 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        awk -v cd="$cert_dir" '
            BEGIN { ins=0 }
            /^\[global\][[:space:]]*$/ && !ins {
                print
                print "\ttls keyfile = " cd "/key.pem"
                print "\ttls certfile = " cd "/cert.pem"
                print "\ttls cafile = " cd "/ca.pem"
                ins=1; next
            }
            { print }
        ' "$smb" > "$tmp" && mv "$tmp" "$smb"
    fi

    systemctl restart samba-ad-dc 2>/dev/null || true
    echo "[sconfig] TLS cert installed"
}

generate_tls_cert() {
    is_provisioned || { info "Not provisioned."; return; }
    local cert_dir="/var/lib/samba/private/tls"
    [[ -f "$cert_dir/cert.pem" ]] && ! yesno "Cert exists. Regenerate?" && return
    whiptail --infobox "Generating TLS certificate..." 6 50
    _generate_tls_cert_core
    info "TLS cert generated at ${cert_dir}/\nReplace with CA-signed cert for production."
}

show_hardening_status() {
    local st=""
    if is_provisioned; then
        local smb="/etc/samba/smb.conf"
        st+="SMB Signing:     $(grep -q 'server signing = mandatory' "$smb" 2>/dev/null && echo 'ENFORCED' || echo 'not enforced')\n"
        st+="Min Protocol:    $(grep -oP '(?<=server min protocol = ).*' "$smb" 2>/dev/null | head -1 || echo 'default')\n"
        st+="LDAP Strong:     $(grep -q 'ldap server require strong auth = yes' "$smb" 2>/dev/null && echo 'YES' || echo 'no')\n"
        st+="Kerberos:        $(grep -q 'aes256' "$smb" 2>/dev/null && echo 'AES only' || echo 'default (incl RC4)')\n"
        st+="NTLM:            $(grep -oP '(?<=ntlm auth = ).*' "$smb" 2>/dev/null | head -1 || echo 'default')\n"
        st+="TLS Enabled:     $(grep -q 'tls enabled = yes' "$smb" 2>/dev/null && echo 'YES' || echo 'no')\n"
        st+="TLS Cert:        $([[ -f /var/lib/samba/private/tls/cert.pem ]] && echo 'present' || echo 'not generated')\n"
        st+="Audit:           $(grep -q 'auth_audit:3' "$smb" 2>/dev/null && echo 'enabled' || echo 'default')\n"
    else
        st+="Domain not provisioned.\n"
    fi
    st+="\nFirewall:        $(nft list ruleset 2>/dev/null | grep -q 'filter' && echo 'active' || echo 'inactive')\n"
    st+="PowerShell SSH:  $(grep -q 'Subsystem.*powershell' /etc/ssh/sshd_config 2>/dev/null && echo 'enabled' || echo 'not configured')\n"
    st+="Update Policy:   $(get_update_policy)\n"

    whiptail --title "Hardening Status" --msgbox "$st" 22 64
}

#===============================================================================
# 6. DIAGNOSTICS
#===============================================================================
menu_diagnostics() {
    while true; do
        local choice
        choice=$(whiptail --title "Diagnostics" \
            --menu "Run tests on this DC." \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Full Sanity Check" \
            "2" "Test DNS Records" \
            "3" "Test Kerberos (kinit)" \
            "4" "Test SMB Shares" \
            "5" "Domain Level & FSMO Roles" \
            "6" "Replication Status" \
            "7" "Samba Logs (last 50)" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) run_full_sanity ;;
            2) test_dns ;;
            3) test_kerberos ;;
            4) test_smb ;;
            5) show_domain_info ;;
            6) test_replication ;;
            7) show_logs ;;
            B|b) return ;;
        esac
    done
}

run_full_sanity() {
    local r="" pass=0 fail=0 wrn=0
    r+="=== Sanity Check === $(date)\nHost: $(get_fqdn)\n\n"

    # Services
    r+="[Services]\n"
    is_addc_running && { r+="  ✓ samba-ad-dc running\n"; ((pass++)); } || { r+="  ✗ samba-ad-dc NOT running\n"; ((fail++)); }
    systemctl is-active chrony &>/dev/null && { r+="  ✓ chrony running\n"; ((pass++)); } || { r+="  ! chrony not running\n"; ((wrn++)); }

    # DNS
    r+="\n[DNS]\n"
    local rl fq
    rl=$(get_realm | tr '[:upper:]' '[:lower:]' 2>/dev/null)
    fq=$(get_fqdn)

    dig @localhost "$fq" +short 2>/dev/null | grep -q '[0-9]' && { r+="  ✓ A record resolves\n"; ((pass++)); } || { r+="  ✗ A record missing\n"; ((fail++)); }
    dig -t SRV @localhost "_ldap._tcp.${rl}" +short 2>/dev/null | grep -q '[0-9]' && { r+="  ✓ _ldap._tcp SRV\n"; ((pass++)); } || { r+="  ✗ _ldap._tcp SRV missing\n"; ((fail++)); }
    dig -t SRV @localhost "_kerberos._tcp.${rl}" +short 2>/dev/null | grep -q '[0-9]' && { r+="  ✓ _kerberos._tcp SRV\n"; ((pass++)); } || { r+="  ✗ _kerberos._tcp SRV missing\n"; ((fail++)); }
    dig @localhost google.com +short 2>/dev/null | grep -q '[0-9]' && { r+="  ✓ DNS forwarding works\n"; ((pass++)); } || { r+="  ! forwarding failed\n"; ((wrn++)); }

    # Kerberos
    r+="\n[Kerberos]\n"
    klist -s 2>/dev/null && { r+="  ✓ Valid TGT\n"; ((pass++)); } || { r+="  ! No TGT (run kinit)\n"; ((wrn++)); }

    # SMB
    r+="\n[SMB]\n"
    smbclient -L localhost -U% -N 2>/dev/null | grep -q 'sysvol' && { r+="  ✓ sysvol accessible\n"; ((pass++)); } || { r+="  ✗ sysvol missing\n"; ((fail++)); }
    smbclient -L localhost -U% -N 2>/dev/null | grep -q 'netlogon' && { r+="  ✓ netlogon accessible\n"; ((pass++)); } || { r+="  ✗ netlogon missing\n"; ((fail++)); }

    # Winbind
    r+="\n[Winbind]\n"
    wbinfo -p 2>/dev/null | grep -q 'succeeded' && { r+="  ✓ winbind ping OK\n"; ((pass++)); } || { r+="  ! winbind ping failed\n"; ((wrn++)); }
    getent passwd administrator &>/dev/null && { r+="  ✓ NSS resolves administrator\n"; ((pass++)); } || { r+="  ! cannot resolve administrator\n"; ((wrn++)); }

    # Hostname
    r+="\n[Hostname]\n"
    local hosts_ip actual_ip
    hosts_ip=$(grep -m1 "$(hostname -s)" /etc/hosts 2>/dev/null | awk '{print $1}')
    actual_ip=$(get_ip | cut -d/ -f1)
    [[ "$hosts_ip" == "$actual_ip" ]] && { r+="  ✓ /etc/hosts matches interface\n"; ((pass++)); } || { r+="  ✗ IP mismatch (hosts=$hosts_ip iface=$actual_ip)\n"; ((fail++)); }

    # PowerShell
    r+="\n[PowerShell]\n"
    command -v pwsh &>/dev/null && { r+="  ✓ pwsh installed ($(pwsh --version 2>/dev/null))\n"; ((pass++)); } || { r+="  ! pwsh not installed\n"; ((wrn++)); }
    grep -q 'Subsystem.*powershell' /etc/ssh/sshd_config 2>/dev/null && { r+="  ✓ SSH remoting configured\n"; ((pass++)); } || { r+="  ! SSH remoting not configured\n"; ((wrn++)); }

    r+="\n========================================\n"
    r+="PASSED: $pass | WARNINGS: $wrn | FAILED: $fail\n"
    [[ $fail -eq 0 ]] && r+="\nOverall: HEALTHY" || r+="\nOverall: ISSUES DETECTED"

    whiptail --title "Sanity Check" --scrolltext --msgbox "$r" 34 76
}

test_dns() {
    is_provisioned || { info "Not provisioned."; return; }
    local rl fq out
    rl=$(get_realm | tr '[:upper:]' '[:lower:]'); fq=$(get_fqdn)
    out="=== DNS Tests ===\n\n"
    out+="A ($fq):\n$(dig @localhost "$fq" +short 2>&1)\n\n"
    out+="_ldap._tcp:\n$(dig -t SRV @localhost "_ldap._tcp.${rl}" +short 2>&1)\n\n"
    out+="_kerberos._tcp:\n$(dig -t SRV @localhost "_kerberos._tcp.${rl}" +short 2>&1)\n\n"
    out+="_gc._tcp:\n$(dig -t SRV @localhost "_gc._tcp.${rl}" +short 2>&1)\n\n"
    out+="Forwarding (google.com):\n$(dig @localhost google.com +short 2>&1)\n"
    whiptail --title "DNS" --scrolltext --msgbox "$out" 26 76
}

test_kerberos() {
    is_provisioned || { info "Not provisioned."; return; }
    local pass; pass=$(whiptail --passwordbox "Administrator password:" 10 60 3>&1 1>&2 2>&3) || return
    local out; out=$(echo "$pass" | kinit administrator 2>&1); out+="\n\n$(klist 2>&1)"
    whiptail --title "Kerberos" --scrolltext --msgbox "$out" 20 76
}

test_smb() {
    whiptail --title "SMB" --scrolltext --msgbox "$(smbclient -L localhost -U% -N 2>&1)" 20 76
}

show_domain_info() {
    is_provisioned || { info "Not provisioned."; return; }
    local out="=== Domain ===\n\n$(samba-tool domain level show 2>&1)\n\nFSMO:\n$(samba-tool fsmo show 2>&1)\n"
    whiptail --title "Domain Info" --scrolltext --msgbox "$out" 24 76
}

test_replication() {
    is_provisioned || { info "Not provisioned."; return; }
    whiptail --title "Replication" --scrolltext --msgbox "$(samba-tool drs showrepl 2>&1)" 24 76
}

show_logs() {
    whiptail --title "Logs (last 50)" --scrolltext --msgbox "$(journalctl -u samba-ad-dc -n 50 --no-pager 2>&1)" 24 76
}

#===============================================================================
# 7. SERVICE MANAGEMENT
#===============================================================================
menu_services() {
    while true; do
        local addc chr nft
        addc=$(systemctl is-active samba-ad-dc 2>/dev/null || echo "inactive")
        chr=$(systemctl is-active chrony 2>/dev/null || echo "inactive")
        nft=$(systemctl is-active nftables 2>/dev/null || echo "inactive")

        local choice
        choice=$(whiptail --title "Services" \
            --menu "samba-ad-dc: $addc | chrony: $chr | nftables: $nft" \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Start samba-ad-dc" \
            "2" "Stop samba-ad-dc" \
            "3" "Restart samba-ad-dc" \
            "4" "Start chrony" \
            "5" "Restart chrony" \
            "6" "Full status" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) systemctl start samba-ad-dc; info "Started." ;;
            2) systemctl stop samba-ad-dc; info "Stopped." ;;
            3) systemctl restart samba-ad-dc; sleep 2
               is_addc_running && info "Restarted." || info "FAILED. Check logs." ;;
            4) systemctl start chrony; info "Started." ;;
            5) systemctl restart chrony; info "Restarted." ;;
            6) whiptail --title "Status" --scrolltext --msgbox \
                "$(systemctl status samba-ad-dc chrony nftables 2>&1 | head -40)" 24 76 ;;
            B|b) return ;;
        esac
    done
}

#===============================================================================
# 8. POWER
#===============================================================================
menu_power() {
    local choice
    choice=$(whiptail --title "Power" --menu "" 12 50 4 \
        "1" "Reboot" "2" "Shutdown" "B" "Back" \
        3>&1 1>&2 2>&3) || return
    case "$choice" in
        1) yesno "Reboot now?" && reboot ;;
        2) yesno "Shutdown now?" && shutdown -h now ;;
    esac
}

#===============================================================================
# HEADLESS CLI (testing / automation)
#
# The TUI is the primary UX. These subcommands mirror a subset of the TUI
# operations for scripted verification (see test-results/ regression runs)
# and so `run-tests.sh` can drive the appliance without `expect`.
# Add new commands here when a test needs to exercise TUI behavior. Prefer a
# narrow command that reuses existing helpers over automating whiptail screens;
# the latter is brittle and tends to hide the real failure output.
#===============================================================================
cli_probe_fl() {
    local dc="${1:?usage: samba-sconfig probe-fl <dc-fqdn-or-ip>}"
    probe_forest_fl "$dc"
}

cli_join_dc() {
    : "${SC_REALM:?SC_REALM env var required}"
    : "${SC_NETBIOS:?SC_NETBIOS env var required}"
    : "${SC_DC:?SC_DC env var required (target DC FQDN or IP)}"
    : "${SC_PASS:?SC_PASS env var required}"
    SC_FWD="${SC_FWD:-$SC_DC}"
    SC_ROLE="${SC_ROLE:-DC}"           # DC or RODC
    SC_ADMIN="${SC_ADMIN:-Administrator}"

    local DC_REALM="${SC_REALM^^}"
    local DC_NETBIOS="${SC_NETBIOS^^}"
    local DC_ADMIN_USER="$SC_ADMIN"
    local DC_ADMIN_PASS="$SC_PASS"
    local DC_DNS_FORWARDER="$SC_FWD"

    local dc_ip
    if ! dc_ip=$(resolve_dc_ip "$SC_DC"); then
        echo "[sconfig] cannot resolve SC_DC='$SC_DC' via the current resolver — pass an IP or fix /etc/resolv.conf" >&2
        return 1
    fi

    local fl_str
    fl_str=$(probe_forest_fl "$dc_ip")
    echo "[sconfig] forest FL probe: $fl_str"

    rm -f /etc/samba/smb.conf
    systemctl stop samba-ad-dc 2>/dev/null || true
    write_krb5_conf "$DC_REALM"
    take_over_resolv_conf
    echo -e "search ${DC_REALM,,}\nnameserver ${dc_ip}" > /etc/resolv.conf

    echo "[sconfig] joining $DC_REALM as $SC_ROLE via $SC_DC ($dc_ip), user=${DC_NETBIOS}\\${DC_ADMIN_USER}, FL=$fl_str..."
    if samba-tool domain join "$DC_REALM" "$SC_ROLE" \
        --dns-backend=SAMBA_INTERNAL \
        --option="dns forwarder = $DC_DNS_FORWARDER" \
        --option="ad dc functional level = $fl_str" \
        -U"${DC_NETBIOS}\\${DC_ADMIN_USER}" \
        --password="$DC_ADMIN_PASS"; then
        apply_hardening_to_smb_conf
        post_provision_setup "$DC_REALM" "$DC_DNS_FORWARDER"
        register_own_ptr "$dc_ip" "$DC_NETBIOS" "$DC_ADMIN_USER" "$DC_ADMIN_PASS" "$DC_REALM" || true
        seed_sysvol "$dc_ip" "$DC_NETBIOS" "$DC_ADMIN_USER" "$DC_ADMIN_PASS" "$DC_REALM" || true
        configure_chrony_for_domain "$dc_ip"
        _generate_tls_cert_core
        echo "[sconfig] JOIN SUCCESS (FL=$fl_str) — TLS cert has SAN, PTR registered, SYSVOL seeded"
    else
        local rc=$?
        echo "[sconfig] JOIN FAILED (rc=$rc)" >&2
        return "$rc"
    fi
}

cli_provision_new() {
    : "${SC_REALM:?SC_REALM env var required}"
    : "${SC_NETBIOS:?SC_NETBIOS env var required}"
    : "${SC_PASS:?SC_PASS env var required (Administrator password to set)}"
    SC_FWD="${SC_FWD:-1.1.1.1}"

    local DC_REALM="${SC_REALM^^}"
    local DC_NETBIOS="${SC_NETBIOS^^}"
    local DC_ADMIN_PASS="$SC_PASS"
    local DC_DNS_FORWARDER="$SC_FWD"

    echo "[sconfig] provisioning new forest $DC_REALM (NetBIOS=$DC_NETBIOS)..."
    rm -f /etc/samba/smb.conf
    systemctl stop samba-ad-dc 2>/dev/null || true
    write_krb5_conf "$DC_REALM"

    if samba-tool domain provision \
            --realm="$DC_REALM" --domain="$DC_NETBIOS" \
            --server-role=dc --dns-backend=SAMBA_INTERNAL \
            --adminpass="$DC_ADMIN_PASS" \
            --option="dns forwarder = $DC_DNS_FORWARDER" 2>&1 | tail -10; then
        apply_hardening_to_smb_conf
        post_provision_setup "$DC_REALM" "$DC_DNS_FORWARDER"
        _generate_tls_cert_core
        echo "[sconfig] PROVISION SUCCESS (realm=$DC_REALM, netbios=$DC_NETBIOS)"
    else
        local rc=$?
        echo "[sconfig] PROVISION FAILED (rc=$rc)" >&2
        return "$rc"
    fi
}

cli_dfs_init_inner() {
    local share="$1" root="$2"
    [[ -n "$share" && -n "$root" ]] || { echo "[dfs-init] share and root required" >&2; return 1; }
    [[ "$root" = /* ]] || { echo "[dfs-init] root must be absolute" >&2; return 1; }
    install -d -m 0755 "$root"
    : > "${root}/${DFS_SENTINEL_NAME}"
    chmod 0644 "${root}/${DFS_SENTINEL_NAME}"
    _dfs_write_drop_in "$root" "$share"
    if [[ ! -f "$DFS_CONF" ]]; then
        cat > "$DFS_CONF" <<CONFEOF
# Managed by samba-sconfig dfs-* commands.
DFS_ROOT="${root}"
DFS_SHARE="${share}"
DFS_NAMESPACES=""
DFS_PREFER=""
CONFEOF
        chmod 0644 "$DFS_CONF"
    else
        sed -i \
            -e "s|^DFS_ROOT=.*|DFS_ROOT=\"${root}\"|" \
            -e "s|^DFS_SHARE=.*|DFS_SHARE=\"${share}\"|" \
            "$DFS_CONF"
    fi
    smbcontrol all reload-config 2>/dev/null || true
    echo "[dfs-init] done. Configure namespaces with: samba-sconfig dfs-configure NS1 [NS2 ...]"
}

cli_dfs_init() {
    local share="${SC_DFS_SHARE:-$DFS_DEFAULT_SHARE}"
    local root="${SC_DFS_ROOT:-$DFS_DEFAULT_ROOT}"
    cli_dfs_init_inner "$share" "$root"
}

cli_dfs_configure() {
    [[ -f "$DFS_CONF" ]] || { echo "[dfs-configure] run dfs-init first" >&2; return 1; }
    # shellcheck disable=SC1090
    source "$DFS_CONF"
    local ns_list="${SC_DFS_NS:-$*}"
    local prefer="${SC_DFS_PREFER:-${DFS_PREFER:-}}"
    [[ -z "$ns_list" ]] && { echo "[dfs-configure] no namespaces given" >&2; return 1; }
    local n
    for n in $ns_list; do
        # Reuse the same character class we trust for path components.
        [[ "$n" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "[dfs-configure] reject namespace name: $n" >&2; return 1; }
        install -d -m 0755 "${DFS_ROOT:-$DFS_DEFAULT_ROOT}/${n}"
        : > "${DFS_ROOT:-$DFS_DEFAULT_ROOT}/${n}/${DFS_SENTINEL_NAME}"
    done
    sed -i \
        -e "s|^DFS_NAMESPACES=.*|DFS_NAMESPACES=\"${ns_list}\"|" \
        -e "s|^DFS_PREFER=.*|DFS_PREFER=\"${prefer}\"|" \
        "$DFS_CONF"
    echo "[dfs-configure] namespaces=${ns_list} prefer=${prefer:-<none>}"
}

cli_dfs_update() {
    _dfs_run_update
}

cli_dfs_schedule_inner() {
    local interval="$1"
    [[ -n "$interval" ]] || { echo "[dfs-schedule] interval required" >&2; return 1; }
    _dfs_install_units "$interval"
    echo "[dfs-schedule] timer enabled, interval=$interval"
    systemctl status --no-pager samba-dfs-update.timer | head -8 || true
}

cli_dfs_schedule() {
    local interval="${SC_DFS_INTERVAL:-30min}"
    cli_dfs_schedule_inner "$interval"
}

cli_dfs_status() {
    echo "Drop-in:    ${DFS_INCLUDE_FILE} $([[ -f $DFS_INCLUDE_FILE ]] && echo present || echo absent)"
    echo "Config:     ${DFS_CONF} $([[ -f $DFS_CONF ]] && echo present || echo absent)"
    if [[ -f "$DFS_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$DFS_CONF"
        echo "Root:       ${DFS_ROOT:-?}"
        echo "Share:      ${DFS_SHARE:-?}"
        echo "Namespaces: ${DFS_NAMESPACES:-<none>}"
        echo "Prefer:     ${DFS_PREFER:-<none>}"
    fi
    # `systemctl is-active` always prints a status word to stdout (even on
    # failure) and exits non-zero when the unit isn't active. Capturing
    # via $() takes that stdout; the previous form added a redundant
    # `|| echo inactive` that produced a doubled status line.
    local _t _s
    _t=$(systemctl is-active samba-dfs-update.timer 2>/dev/null)
    _s=$(systemctl is-active samba-dfs-update.service 2>/dev/null)
    echo "Timer:      ${_t:-unknown}"
    echo "Service:    ${_s:-unknown}"
    if [[ -f "$DFS_LOG" ]]; then
        echo
        echo "--- last 12 log lines ---"
        tail -12 "$DFS_LOG"
    fi
    if [[ -f "$DFS_CONF" ]] && [[ -d "${DFS_ROOT:-$DFS_DEFAULT_ROOT}" ]]; then
        echo
        echo "--- managed symlinks ---"
        find "${DFS_ROOT:-$DFS_DEFAULT_ROOT}" -mindepth 1 -type l -printf '%P -> %l\n' 2>/dev/null | head -40 || true
    fi
}

cli_dfs_remove() {
    _dfs_remove_units
    _dfs_remove_drop_in
    rm -f "$DFS_CONF"
    smbcontrol all reload-config 2>/dev/null || true
    echo "[dfs-remove] units, drop-in, and config removed."
    echo "[dfs-remove] filesystem under ${DFS_DEFAULT_ROOT} left intact (rm -rf manually if desired)."
}

usage_cli() {
    cat <<USAGE
Usage: samba-sconfig                       # interactive TUI
       samba-sconfig probe-fl <dc>         # print detected forest FL string
       samba-sconfig join-dc               # headless join
           required env: SC_REALM, SC_NETBIOS, SC_DC (FQDN or IP), SC_PASS
           optional env: SC_FWD (default: SC_DC)
                         SC_ROLE=DC|RODC (default: DC)
                         SC_ADMIN (default: Administrator) — any domain
                                  account with join rights
       samba-sconfig provision-new         # headless new-forest provision
           required env: SC_REALM, SC_NETBIOS, SC_PASS
           optional env: SC_FWD (default: 1.1.1.1)

DFS-N (domain-based namespace tertiary target):
       samba-sconfig dfs-init              # install drop-in share + sentinel
           optional env: SC_DFS_ROOT (default: ${DFS_DEFAULT_ROOT})
                         SC_DFS_SHARE (default: ${DFS_DEFAULT_SHARE})
       samba-sconfig dfs-configure NS [NS ...]
                                           # set namespaces and prefer-regex
           optional env: SC_DFS_NS (overrides positional list)
                         SC_DFS_PREFER (extended regex; matches bubble to front)
       samba-sconfig dfs-update            # one sync pass
           optional env: SC_DFS_DRY_RUN=1  (no filesystem writes)
       samba-sconfig dfs-schedule          # install systemd timer
           optional env: SC_DFS_INTERVAL (default: 30min)
       samba-sconfig dfs-status            # show config, units, recent log
       samba-sconfig dfs-remove            # tear down (filesystem left alone)
USAGE
}

#===============================================================================
# ENTRY
#===============================================================================
check_root

case "${1:-}" in
    "")             main_menu ;;
    probe-fl)       shift; cli_probe_fl "$@" ;;
    join-dc)        cli_join_dc ;;
    provision-new)  cli_provision_new ;;
    dfs-init)       cli_dfs_init ;;
    dfs-configure)  shift; cli_dfs_configure "$@" ;;
    dfs-update)     cli_dfs_update ;;
    dfs-schedule)   cli_dfs_schedule ;;
    dfs-status)     cli_dfs_status ;;
    dfs-remove)     cli_dfs_remove ;;
    -h|--help)      usage_cli ;;
    *)              echo "Unknown subcommand: $1" >&2; usage_cli >&2; exit 2 ;;
esac

#!/usr/bin/env bash
#===============================================================================
# prepare-image.sh — Samba AD DC Appliance Image Preparation
#
# Run ONCE on a fresh Debian 13 (Trixie) minimal install to:
#   - Remove unnecessary packages (spell check, X11, laptop detection, etc.)
#   - Install Samba AD DC, Kerberos, Chrony, PowerShell, and tooling
#   - Conditionally install VM guest agents (QEMU, VMware, Hyper-V)
#   - Pre-configure skeleton files for samba-sconfig deployment
#   - Install the unattended-upgrades framework (policy set by sconfig)
#
# After running, snapshot the VM. Use samba-sconfig for per-deployment config.
#
# Design rule: this script prepares an image, but it does not decide the
# domain. Anything that depends on the eventual realm, source DC, client
# subnet, or deployment role belongs in samba-sconfig.sh. That is why files
# such as krb5.conf and chrony.conf are skeletons here and are completed
# later during provision or join.
#
# Usage: sudo bash prepare-image.sh
#===============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

#===============================================================================
# 0. REFRESH APT INDEXES
#===============================================================================
# Debian cloud images ship with /var/lib/apt/lists/ cleaned to keep the image
# small. Without an `apt-get update` first, any subsequent `apt-get install`
# of a package that wasn't in the build-time index — for example the
# hyperv-daemons install in section 2 — fails with "Unable to locate
# package". Section 3 also runs apt-get update + upgrade; the redundant
# update there is a no-op and not worth removing.
log "Refreshing apt indexes..."
apt-get update -y

#===============================================================================
# 1. REMOVE UNNECESSARY PACKAGES
#===============================================================================
# This is a special-purpose AD DC appliance: LDAP, Kerberos, SMB, DNS, and
# domain time. Administration is SSH plus samba-sconfig. The package purge
# below removes general-purpose Debian extras that add attack surface, boot
# noise, or image size but do not help a VM domain controller. Keep this list
# conservative; predictable image preparation matters more than shaving every
# possible package.
log "Removing unnecessary packages to minimize image size..."

REMOVE_PKGS=(
    # Spell-check stack
    ispell iamerican ibritish ienglish-common wamerican
    dictionaries-common emacsen-common
    # Post-install / installer artifacts
    installation-report
    tasksel tasksel-data task-english
    # Multi-boot GRUB probing (useless in VM)
    os-prober
    # Laptop / desktop detection
    laptop-detect
    # Desktop-oriented hooks
    xdg-user-dirs shared-mime-info

    # Mail stack — the appliance sends no mail. apt-listchanges / mailutils
    # pull exim4 in as a Recommends, so explicitly purge the lot. The
    # unattended-upgrades install below uses --no-install-recommends to
    # keep them from sneaking back in.
    exim4 exim4-base exim4-config exim4-daemon-light
    bsd-mailx mailutils
    apt-listchanges

    # Debian community / end-user tooling that has no place on a server
    # appliance we don't hand out to end users.
    reportbug python3-reportbug
    popularity-contest
    debian-faq doc-debian

    # debconf prompts only run in English on this appliance (locale is set
    # to en_US.UTF-8 below); the ~2 MB of translation catalogs aren't used.
    debconf-i18n

    # Real-hardware bits that never apply to a VM DC.
    discover discover-data
    # Wireless — VMs don't have radios. The regulatory DB alone is ~1 MB.
    wpasupplicant wireless-regdb crda iw
    # Bluetooth
    bluez bluetooth
    # Audio
    alsa-utils pulseaudio
)

# cloud-init depends on eject, so removing eject in the initial pass would also
# remove the command needed to erase the build seed. Purge both afterward.
DEFERRED_REMOVE_PKGS=(cloud-init eject)
for pkg in "${DEFERRED_REMOVE_PKGS[@]}"; do
    if dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx installed; then
        apt-mark manual "$pkg" >/dev/null
    fi
done

for pkg in "${REMOVE_PKGS[@]}"; do
    if dpkg -l "$pkg" &>/dev/null 2>&1; then
        apt-get purge -y "$pkg" 2>/dev/null || true
    fi
done

apt-get autoremove -y --purge
apt-get clean
log "Package cleanup complete."

#===============================================================================
# 2. PRE-DOWNLOAD GUEST AGENTS (no install)
#===============================================================================
# This image is host-agnostic: the same prepared snapshot must work on Hyper-V,
# KVM/QEMU, or VMware regardless of where it was mastered. Detecting the
# hypervisor here and installing only the matching agent would lock the image
# to that environment.
#
# Instead, pre-download a self-contained .deb bundle for each supported
# hypervisor into /var/cache/samba-appliance/vmtools/<pkg>/. At the deployed
# VM's first boot, samba-firstboot.service detects the actual hypervisor and
# does an offline `dpkg -i` from the matching cache directory, then deletes
# the rest. This works even if the deployment-side NIC isn't yet recognized,
# because no internet access is required at first boot.
#
# Manifest: /var/cache/samba-appliance/vmtools/manifest maps systemd-detect-virt
# return values to package names. Single source of truth for the firstboot
# script.
log "Pre-downloading guest agents and cloud helpers for all supported targets..."

VMTOOLS_CACHE="/var/cache/samba-appliance/vmtools"
mkdir -p "$VMTOOLS_CACHE"

# Per-virt package set installed by samba-firstboot when that virt-type is
# detected. Each value is a space-separated list. Everything below is in
# Debian's main archive and DFSG-free — freely redistributable.
#
# Notes on what's NOT pre-staged and why:
#   - virtualbox-guest-utils ships in contrib, not main, so the cloud
#     image's sources don't carry it. VirtualBox deployments can install
#     it manually after enabling contrib.
#   - walinuxagent isn't in Trixie main; modern Azure setups use cloud-init
#     for the things walinuxagent used to handle, so we just install
#     cloud-init on Azure.
#   - xe-guest-utilities isn't in Trixie main either; a kernel-level Xen
#     guest works without it.
declare -A VIRT_PKGS=(
    ["amazon"]="qemu-guest-agent cloud-init cloud-guest-utils"
    ["kvm"]="qemu-guest-agent cloud-guest-utils"
    ["qemu"]="qemu-guest-agent cloud-guest-utils"
    ["microsoft"]="hyperv-daemons cloud-guest-utils"
    ["vmware"]="open-vm-tools cloud-guest-utils"
    ["oracle"]="cloud-guest-utils"
    ["xen"]="qemu-guest-agent cloud-guest-utils"
)

# samba-firstboot may augment the install list dynamically based on DMI
# probes (e.g. add cloud-init when the chassis-asset-tag identifies Azure
# inside an otherwise generic 'microsoft' virt-type). Anything that may
# be promoted that way needs to be in the cache regardless of the static
# manifest, so we pre-fetch it as an extra here.
EXTRA_DOWNLOADS="cloud-init"

# Union of every package across every virt + the extras — what we actually
# need to fetch. Per-package directories give samba-firstboot a clean
# "install just this package's cache" target.
declare -A PKGS_SEEN
for virt in "${!VIRT_PKGS[@]}"; do
    for pkg in ${VIRT_PKGS[$virt]}; do
        PKGS_SEEN[$pkg]=1
    done
done
for pkg in $EXTRA_DOWNLOADS; do
    PKGS_SEEN[$pkg]=1
done

for pkg in "${!PKGS_SEEN[@]}"; do
    dest="$VMTOOLS_CACHE/$pkg"
    mkdir -p "$dest/partial"
    log "  pre-download $pkg -> $dest"
    # --download-only puts .debs in Dir::Cache::archives without installing.
    # --reinstall forces a re-download even when the package is already on
    # the prepared image (cloud-guest-utils is shipped on the Debian cloud
    # base; without --reinstall apt would say "nothing to do" and leave
    # us with an empty cache). --no-install-recommends keeps each bundle
    # small.
    if ! apt-get install -y --download-only --reinstall --no-install-recommends \
            -o "Dir::Cache::archives=$dest" \
            "$pkg" 2>&1 | tail -3; then
        warn "    WARN: download of $pkg failed (not in Debian main on this release; skipping)"
    fi
    rm -rf "$dest/partial"
done

# Manifest in a stable format the firstboot script can read.
{
    echo "# samba-appliance guest-agent / cloud-helper manifest"
    echo "# format: systemd-detect-virt-value=space-separated-package-list"
    echo "# (samba-firstboot may augment this list dynamically — e.g. on Azure)"
    for virt in "${!VIRT_PKGS[@]}"; do
        printf '%s=%s\n' "$virt" "${VIRT_PKGS[$virt]}"
    done | sort
} > "$VMTOOLS_CACHE/manifest"

log "  staged cache (per-package):"
du -sh "$VMTOOLS_CACHE"/* 2>/dev/null | sed 's|^|    |'

#===============================================================================
# 3. SYSTEM UPDATE
#===============================================================================
log "Updating package index and upgrading system..."
apt-get update -y
apt-get full-upgrade -y

#===============================================================================
# 4. BASE TOOLS (replaces manual post-install steps)
#===============================================================================
log "Installing base administration tools..."
apt-get install -y \
    sudo \
    nano \
    iputils-ping \
    net-tools \
    dnsutils \
    wget \
    curl \
    htop \
    tree \
    rsync \
    bash-completion \
    locales-all \
    whiptail \
    nftables \
    ldap-utils

#===============================================================================
# 5. SAMBA AD DC PACKAGES
#===============================================================================
log "Installing Samba AD DC packages and dependencies..."
apt-get install -y \
    samba \
    samba-ad-dc \
    winbind \
    libnss-winbind \
    libpam-winbind \
    krb5-user \
    smbclient \
    ldb-tools \
    python3-cryptography \
    acl \
    attr

#===============================================================================
# 6. CHRONY NTP
#===============================================================================
log "Installing Chrony..."
apt-get install -y chrony

#===============================================================================
# 7. UNATTENDED-UPGRADES FRAMEWORK
#===============================================================================
log "Installing unattended-upgrades framework..."
# --no-install-recommends: the default Recommends are apt-listchanges (which
# drags in bsd-mailx → exim4), needrestart, powermgmt-base, python3-gi — all
# purged above or irrelevant to a headless DC. Admin can tail
# /var/log/unattended-upgrades/ directly; no mail pathway needed.
apt-get install -y --no-install-recommends unattended-upgrades

# Default to disabled — sconfig sets the policy per deployment
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'UAEOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "7";
UAEOF

#===============================================================================
# 8. POWERSHELL
#===============================================================================
log "Installing Microsoft PowerShell..."

PWSH_INSTALLED=false

# Debian 13 (Trixie) switched apt signature verification to sqv/Sequoia, which
# rejects Microsoft's current repo metadata signature because the published
# keyring is missing the subkey used to sign it. Installing the direct GitHub
# .deb is less elegant than an apt repo, but it is deterministic in this image
# build and avoids leaving a half-configured Microsoft source behind.
rm -f /etc/apt/sources.list.d/microsoft.list /usr/share/keyrings/microsoft-archive-keyring.gpg

PWSH_VER="7.6.4"
PWSH_DEB="powershell_${PWSH_VER}-1.deb_amd64.deb"
PWSH_SHA256="E5688E0569568D48051C49D3E93504CDE47AF709CDAAABD9A8892BC676B3BDF3"
if wget -q "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VER}/${PWSH_DEB}" -O "/tmp/${PWSH_DEB}"; then
    if printf '%s  %s\n' "$PWSH_SHA256" "/tmp/${PWSH_DEB}" | sha256sum -c -; then
        dpkg -i "/tmp/${PWSH_DEB}" 2>/dev/null || true
        apt-get install -f -y
    else
        warn "PowerShell package checksum verification failed"
    fi
    rm -f "/tmp/${PWSH_DEB}"
    if command -v pwsh &>/dev/null; then
        PWSH_INSTALLED=true
        log "PowerShell installed: $(pwsh --version 2>/dev/null)"
    fi
fi

if $PWSH_INSTALLED; then
    log "Configuring PowerShell SSH remoting subsystem..."
    SSHD_CONF="/etc/ssh/sshd_config"
    PWSH_PATH=$(command -v pwsh 2>/dev/null || echo "/usr/bin/pwsh")

    if ! grep -q 'Subsystem.*powershell' "$SSHD_CONF" 2>/dev/null; then
        echo "" >> "$SSHD_CONF"
        echo "# PowerShell SSH Remoting — added by prepare-image.sh" >> "$SSHD_CONF"
        echo "Subsystem powershell ${PWSH_PATH} -sshs -NoLogo -NoProfile" >> "$SSHD_CONF"
        log "  Added PowerShell subsystem to sshd_config"
    fi
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
else
    warn "PowerShell installation failed. Non-critical — install manually later."
fi

#===============================================================================
# 9. SET LOCALE
#===============================================================================
log "Setting system locale to en_US.UTF-8..."
update-locale LANG=en_US.UTF-8
export LANG=en_US.UTF-8

#===============================================================================
# 10. DISABLE AVAHI / mDNS
#===============================================================================
if systemctl is-enabled avahi-daemon.service &>/dev/null 2>&1; then
    log "Disabling avahi-daemon..."
    systemctl stop avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
    systemctl disable avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
fi

#===============================================================================
# 11. CONFIGURE SYSTEMD-RESOLVED  (DHCP-DNS preferred, 1.1.1.1 fallback)
#===============================================================================
# Pre-provision, the appliance is just a regular Debian box and should use
# whatever DNS the deployment network's DHCP supplies. systemd-resolved
# does that automatically — it merges per-link DHCP DNS with global
# fallbacks. We add 1.1.1.1 / 1.0.0.1 as fallbacks so the box still
# resolves names if DHCP didn't provide a DNS server (rare but real).
#
# samba-sconfig disables systemd-resolved and writes its own
# /etc/resolv.conf at provision/join time, when Samba's internal DNS
# starts listening on 127.0.0.1 — that's the right moment to switch.
log "Configuring systemd-resolved (DHCP DNS preferred, 1.1.1.1 fallback)..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/10-samba-appliance.conf <<'RSLVEOF'
[Resolve]
FallbackDNS=1.1.1.1 1.0.0.1
DNSStubListener=yes
RSLVEOF

#===============================================================================
# 12. MASK SAMBA FILE-SERVER SERVICES
#===============================================================================
log "Stopping and disabling Samba services until samba-sconfig takes over..."
systemctl stop samba winbind nmbd smbd samba-ad-dc 2>/dev/null || true
systemctl disable samba winbind nmbd smbd samba-ad-dc 2>/dev/null || true
# Mask only the member/file-server daemons. Do NOT mask samba.service itself:
# on Debian it is also an alias path used by samba-ad-dc.service. A /dev/null
# mask there makes later `systemctl enable samba-ad-dc` look broken even after
# a successful domain provision or join.
systemctl mask winbind nmbd smbd 2>/dev/null || true

#===============================================================================
# 13. REMOVE DEFAULT SMB.CONF
#===============================================================================
log "Removing default smb.conf..."
rm -f /etc/samba/smb.conf

#===============================================================================
# 14. SKELETON KRB5.CONF
#===============================================================================
log "Writing skeleton krb5.conf..."
cat > /etc/krb5.conf << 'KRBEOF'
[libdefaults]
  default_realm = YOURREALM.LAN
  dns_lookup_kdc = true
  dns_lookup_realm = false
KRBEOF

#===============================================================================
# 15. SKELETON CHRONY.CONF
#===============================================================================
log "Writing chrony skeleton..."
# Deliberately no NTP servers here. AD time has topology rules: a joined DC
# should follow the domain source, while a first DC may need to serve the
# client subnet. samba-sconfig knows which case applies; the image builder
# does not. Baking public pools into the golden image also breaks isolated labs.
cat > /etc/chrony/chrony.conf << 'CHRONEOF'
# Time sources are configured per deployment by samba-sconfig.
# Until sconfig runs, this host relies on the hypervisor time-sync service
# (hyperv-daemons / vmware-tools / qemu-guest-agent) if present.

driftfile /var/lib/chrony/drift
ntpsigndsocket /var/lib/samba/ntp_signd
makestep 1.0 3
#allow 192.168.0.0/16   # enabled by samba-sconfig after provision/join
CHRONEOF

#===============================================================================
# 16. BACKUP NSSWITCH.CONF
#===============================================================================
log "Backing up nsswitch.conf..."
cp /etc/nsswitch.conf /etc/nsswitch.conf.orig

#===============================================================================
# 17. NTP SIGNING SOCKET DIRECTORY
#===============================================================================
log "Creating NTP signing socket directory..."
mkdir -p /var/lib/samba/ntp_signd
chown root:_chrony /var/lib/samba/ntp_signd 2>/dev/null || \
chown root:chrony /var/lib/samba/ntp_signd 2>/dev/null || true
chmod 750 /var/lib/samba/ntp_signd

#===============================================================================
# 18. INSTALL SAMBA-SCONFIG
#===============================================================================
log "Installing samba-sconfig tool..."
for src in /root/samba-sconfig.sh /root/samba-sconfig; do
    if [[ -f "$src" ]]; then
        cp "$src" /usr/local/sbin/samba-sconfig
        chmod +x /usr/local/sbin/samba-sconfig
        log "  Installed from $src to /usr/local/sbin/samba-sconfig"
        break
    fi
done
[[ -x /usr/local/sbin/samba-sconfig ]] || warn "samba-sconfig not found — copy it manually to /usr/local/sbin/"

grep -q 'samba-sconfig' /root/.bashrc 2>/dev/null || \
    echo 'alias sconfig="sudo samba-sconfig"' >> /root/.bashrc

#===============================================================================
# 18b. VENDOR APPLIANCE-CORE LIBS
#===============================================================================
# samba-sconfig sources shared bash helpers from
# /usr/local/lib/appliance-core/. The libs come from the sibling
# appliance-core repo and are scp'd to /tmp/lib by the build pipeline
# (see lab/build-fresh-base.sh §5). Vendoring them into the image at
# prep time means a deployed appliance has no runtime cross-repo
# dependency.
#
# Provenance file at /etc/appliance-core.provenance carries the SemVer
# (lib/VERSION, informational) and the git commit hash of the
# appliance-core checkout that built this image (load-bearing
# identity). Hash is computed Mac-side and passed via
# $APPCORE_BUILD_COMMIT.
LIB_TARGET=/usr/local/lib/appliance-core
LIB_SRC=""
for cand in /tmp/lib /root/appliance-core-lib; do
    if [[ -d "$cand" && -f "$cand/detect-net.sh" ]]; then
        LIB_SRC="$cand"; break
    fi
done

if [[ -n "$LIB_SRC" ]]; then
    log "Vendoring appliance-core libs from $LIB_SRC -> $LIB_TARGET ..."
    install -d -m 0755 "$LIB_TARGET"
    install -m 0644 "$LIB_SRC"/*.sh "$LIB_TARGET/"
    [[ -f "$LIB_SRC/VERSION"   ]] && install -m 0644 "$LIB_SRC/VERSION"   "$LIB_TARGET/VERSION"
    [[ -f "$LIB_SRC/README.md" ]] && install -m 0644 "$LIB_SRC/README.md" "$LIB_TARGET/README.md"

    src_count=$(ls -1 "$LIB_SRC"/*.sh 2>/dev/null | wc -l)
    dst_count=$(ls -1 "$LIB_TARGET"/*.sh 2>/dev/null | wc -l)
    if (( src_count == 0 || src_count != dst_count )); then
        err "appliance-core vendoring count mismatch: source $src_count, target $dst_count"
        exit 1
    fi
    for libfile in "$LIB_TARGET"/*.sh; do
        bash -n "$libfile" || { err "vendored lib failed bash -n: $libfile"; exit 1; }
    done
    log "  vendored $dst_count appliance-core lib(s) into $LIB_TARGET"

    PROV_FILE=/etc/appliance-core.provenance
    PROV_COMMIT="${APPCORE_BUILD_COMMIT:-unknown}"
    PROV_CONSUMER_COMMIT="${SAMBA_BUILD_COMMIT:-unknown}"
    PROV_TREE_STATE="${SOURCE_TREE_STATE:-unknown}"
    {
        printf 'appliance-core-version=%s\n' "$(<"$LIB_TARGET/VERSION")"
        printf 'appliance-core-commit=%s\n'  "$PROV_COMMIT"
        printf 'appliance-core-tree-state=%s\n' "$PROV_TREE_STATE"
        printf 'image-built-at=%s\n'         "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'image-built-on=%s\n'         "$(uname -srm)"
        printf 'consumer=samba-addc-appliance\n'
        printf 'consumer-commit=%s\n'         "$PROV_CONSUMER_COMMIT"
        printf 'consumer-tree-state=%s\n'     "$PROV_TREE_STATE"
    } > "$PROV_FILE"
    chmod 0644 "$PROV_FILE"
    log "  provenance: $(tr '\n' ' ' < "$PROV_FILE")"
else
    warn "no appliance-core lib/ source at /tmp/lib or /root/appliance-core-lib"
    warn "samba-sconfig features that depend on the shared libs will fail at runtime"
    warn "fix: ensure lab/build-fresh-base.sh pushes ../appliance-core/lib to /tmp/lib"
fi

#===============================================================================
# 19. STATIC MOTD
#===============================================================================
log "Clearing static MOTD; update-motd.d provides the login status..."
: > /etc/motd

#===============================================================================
# 20. NFTABLES FIREWALL RULESET (inactive)
#===============================================================================
log "Writing AD DC firewall ruleset (inactive)..."
cat > /etc/nftables-samba-addc.conf << 'NFTEOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept
        tcp dport 22 accept
        tcp dport 53 accept
        udp dport 53 accept
        tcp dport 88 accept
        udp dport 88 accept
        udp dport 123 accept
        tcp dport 135 accept
        tcp dport 139 accept
        tcp dport 389 accept
        udp dport 389 accept
        tcp dport 445 accept
        tcp dport 464 accept
        udp dport 464 accept
        tcp dport 636 accept
        tcp dport { 3268, 3269 } accept
        tcp dport 49152-65535 accept
        # level info keeps drop messages off the system console (see
        # /etc/sysctl.d/30-quiet-console.conf for the printk threshold).
        log prefix "nft-drop: " level info limit rate 5/minute
        drop
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output priority 0; policy accept; }
}
NFTEOF

#===============================================================================
# 20b. CONSOLE QUIET + JOURNALD CAPS
#
# Two related defaults the appliance bakes in so an operator never has to
# deal with kernel chatter on the console or an unbounded journal:
#
#   1. Pin kernel.printk console threshold to 4 (WARN). Without this,
#      a default-Debian kernel running with current console_loglevel=7
#      (DEBUG) prints every kernel info/notice line to /dev/console —
#      most visibly the nftables `log` lines from firewall drops, but
#      also boot-time hardware probes, USB events, etc. With threshold
#      4 only WARN/ERR/CRIT/ALERT/EMERG hit the console; everything
#      else still lands in journald (queryable, just quiet).
#
#   2. Bound journald disk usage. Default journald keeps growing until
#      it hits 10% of /var — fine on a 100 GB rootfs, surprising on a
#      small appliance image. Cap at 200 MB total / 50 MB per file.
#      Journald rotates automatically; no logrotate config needed.
#
# These are dropped in under /etc/sysctl.d and /etc/systemd/journald.conf.d
# so deployed images get the right defaults without operator action and
# without overriding any explicit operator config.
#===============================================================================
log "Installing console-quiet + journald-size drop-ins..."
cat > /etc/sysctl.d/30-quiet-console.conf <<'SYSCTLEOF'
# Suppress kernel info/debug/notice messages on the console. They
# still reach journald (`journalctl -k`) but stay off /dev/console
# and serial console. Required so nftables `log` rules don't spam
# the boot console — see /etc/nftables-samba-addc.conf which uses
# `log ... level info` to land just above this threshold.
#   field 1: current console_loglevel — only msgs < this print
#   field 2: default_message_loglevel — printk() default
#   field 3: minimum_console_loglevel — operator-settable floor
#   field 4: default_console_loglevel
# 4 4 1 7 == only WARN and above to console; default messages at
# WARN; floor at 1 (only PANIC blocks operator override).
kernel.printk = 4 4 1 7
SYSCTLEOF
chmod 0644 /etc/sysctl.d/30-quiet-console.conf

install -d -m 0755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/30-appliance-caps.conf <<'JOURNALEOF'
# Cap journald disk usage so a chatty kernel (or noisy AD audit
# output) doesn't fill the rootfs. Journald rotates automatically
# at SystemMaxFileSize, deletes oldest archives when SystemMaxUse
# is exceeded, and reserves SystemKeepFree free space for other
# writers. No logrotate config needed.
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
SystemKeepFree=200M
JOURNALEOF
chmod 0644 /etc/systemd/journald.conf.d/30-appliance-caps.conf

#===============================================================================
# 21. SYSVOL-SYNC HELPER
#===============================================================================
log "Installing sysvol-sync helper..."
cat > /usr/local/sbin/sysvol-sync << 'SYNCEOF'
#!/usr/bin/env bash
#
# sysvol-sync — multi-source, version-aware SYSVOL puller for Samba DCs.
#
# Samba doesn't implement DFSR. This helper keeps /var/lib/samba/sysvol/
# converged with peers (Windows or Samba) by, on each cycle:
#
#   1. discovering all DCs in the forest from the local Samba SAM
#      (objectClass=server under CN=Sites,CN=Configuration);
#   2. classifying each peer Windows vs Samba via the computer object's
#      operatingSystem attribute (Windows DCs get tier 1, Samba peers tier 2);
#   3. probing TCP/445 reachability with a short timeout — unreachable peers
#      are silently skipped, so a multi-day outage of any single DC is fine;
#   4. enumerating local GPOs (objectClass=groupPolicyContainer) and, for
#      each one whose on-disk GPT.INI Version is behind its AD versionNumber,
#      asking each candidate (highest tier first) whether IT has the version
#      we need AND its own LDAP versionNumber matches its on-disk GPT.INI
#      (settled, no DFSR mid-flight). The first peer that answers yes is
#      used as the source.
#   5. The chosen GPO is pulled into a staging tmpdir and rsync'd into place
#      atomically per-GPO, then `samba-tool ntacl sysvolreset` is run once at
#      the end if any GPO actually changed.
#
# Authentication uses smbclient -P (Privileged), which makes Samba's own
# tooling pick up this DC's machine credentials directly from
# /var/lib/samba/private/secrets.tdb. No admin password on disk, no separate
# keytab to manage, no kinit dance — Samba's machine identity is the same
# identity that AD already trusts for replication.
#
# Configuration: /etc/samba/sysvol-sync.conf  (managed by samba-sconfig)
#   PREFERRED_DCS=""    optional, space-separated FQDNs to try first (tier 0)
#   EXCLUDE_DCS=""      optional, space-separated FQDNs to never use as a source
#   SYNC_INTERVAL=15    minutes between cron firings (consumed by samba-sconfig)
#
# CLI:
#   sysvol-sync                  one normal sync cycle (the cron entrypoint)
#   sysvol-sync --status         print a freshness table; do not pull anything

set -u -o pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

CONF="/etc/samba/sysvol-sync.conf"
LOCKFILE="/run/sysvol-sync.lock"
LOGFILE="/var/log/samba/sysvol-sync.log"
SAMDB="/var/lib/samba/private/sam.ldb"
SMBCONF="/etc/samba/smb.conf"

MODE="${1:-sync}"   # sync (default) | --status

mkdir -p "$(dirname "$LOGFILE")"

if [[ "$MODE" == "--status" ]]; then
    say() { printf '%s\n' "$*"; }
else
    say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }
fi
fatal() { say "ERROR: $*"; exit 1; }

[[ -f "$SMBCONF" ]] || fatal "smb.conf not found"
[[ -f "$SAMDB"   ]] || fatal "Samba SAM not found at $SAMDB (DC not provisioned?)"
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF" || true   # config is optional; defaults are fine

PREFERRED_DCS="${PREFERRED_DCS:-}"
EXCLUDE_DCS="${EXCLUDE_DCS:-}"

# Single-instance lock for the sync mode; --status is read-only and skipped.
if [[ "$MODE" == "sync" ]]; then
    exec 200>"$LOCKFILE"
    flock -n 200 || { say "skip: another sysvol-sync is already running"; exit 0; }
fi

# --- environment from smb.conf -------------------------------------------------
read_smbconf_param() {
    awk -v key="$1" -F= '
        $1 ~ "^[[:space:]]*"key"[[:space:]]*$" {
            sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2)
            print $2; exit
        }
    ' "$SMBCONF"
}

REALM=$(read_smbconf_param "realm")
[[ -n "$REALM" ]] || fatal "could not read 'realm' from $SMBCONF"
REALM="${REALM^^}"
REALM_LC="${REALM,,}"
BASE_DN="DC=${REALM_LC//./,DC=}"

NETBIOS_SELF=$(read_smbconf_param "netbios name")
[[ -z "$NETBIOS_SELF" ]] && NETBIOS_SELF="$(hostname -s)"
NETBIOS_SELF="${NETBIOS_SELF^^}"

say "start: realm=$REALM self=$NETBIOS_SELF mode=$MODE"

# --- helpers ------------------------------------------------------------------
ldb() { ldbsearch -H "$SAMDB" "$@" 2>/dev/null; }

# Parse Version= out of a GPT.INI file. Echoes 0 if file missing or malformed.
parse_gpt_ini_version() {
    local ini="$1"
    [[ -f "$ini" ]] || { echo 0; return; }
    local v
    v=$(awk -F= 'tolower($1) ~ /^[[:space:]]*version[[:space:]]*$/ {
                     gsub(/[[:space:]\r]/, "", $2); print $2; exit }' "$ini")
    [[ -n "$v" ]] || v=0
    echo "$v"
}

# Read the local GPT.INI Version for a GPO directory. GPT.INI casing varies
# across GPO authoring tools — Windows serves the file case-insensitively
# over SMB, but Samba stores whichever case the original writer used.
read_local_gpt_version() {
    local dir="$1"          # /var/lib/samba/sysvol/<realm>/Policies/{GUID}
    for cand in "$dir/GPT.INI" "$dir/gpt.ini" "$dir/Gpt.ini"; do
        [[ -f "$cand" ]] && { parse_gpt_ini_version "$cand"; return; }
    done
    echo 0
}

# Pull a single file from a peer's sysvol share into a local destination.
# -P (Privileged) tells Samba's smbclient to authenticate using the local
# DC's machine credentials directly from secrets.tdb, no kinit / keytab /
# password file needed.
fetch_one_file() {
    local fqdn="$1" remote="$2" out="$3"
    smbclient "//${fqdn}/sysvol" -P --quiet \
        -c "get \"$remote\" \"$out\"" >/dev/null 2>&1
}

# Settled GPT version on a peer for a given GUID. Echoes -1 on any error.
# Probes both common GPT.INI casings (the SMB server normalizes case, but
# we don't know which spelling the file was actually written under until we
# ask — and `get GPT.INI` will only succeed for the actual stored name).
fetch_remote_gpt_version() {
    local fqdn="$1" guid="$2" tmp
    tmp=$(mktemp /tmp/gpt-probe-XXXXXX.ini)
    local got=0
    for fname in GPT.INI gpt.ini Gpt.ini; do
        if fetch_one_file "$fqdn" "$REALM_LC/Policies/$guid/$fname" "$tmp"; then
            got=1
            break
        fi
    done
    if [[ $got -eq 1 ]]; then
        parse_gpt_ini_version "$tmp"
    else
        echo "-1"
    fi
    rm -f "$tmp"
}

# TCP probe with a short timeout. /dev/tcp on bash is enough; we don't need nc.
probe_reachable() {
    timeout 2 bash -c "exec 9<>/dev/tcp/$1/445" >/dev/null 2>&1
}

# --- enumerate GPOs (local SAM, no network needed) ----------------------------
declare -A target_versions
while IFS=$'\t' read -r guid ver; do
    [[ -z "$guid" ]] && continue
    target_versions["$guid"]="$ver"
done < <(
    ldb -b "CN=Policies,CN=System,${BASE_DN}" \
        "(objectClass=groupPolicyContainer)" cn versionNumber \
    | awk '
        function reset() { cn=""; ver="" }
        BEGIN { reset() }
        /^[Dd][Nn]:/ { reset(); next }
        /^[^:]+:[[:space:]]/ {
            ix = index($0, ":")
            attr = tolower(substr($0, 1, ix - 1))
            val  = substr($0, ix + 2)
            if      (attr == "cn")            cn  = val
            else if (attr == "versionnumber") ver = val
            next
        }
        /^$/ {
            if (cn != "" && ver != "") printf "%s\t%s\n", cn, ver
            reset()
        }
        END { if (cn != "" && ver != "") printf "%s\t%s\n", cn, ver }
    '
)

# --- --status mode: print freshness table, no remote network calls -----------
if [[ "$MODE" == "--status" ]]; then
    printf '\n%-40s %10s %10s %s\n' "GPO GUID" "local" "AD" "status"
    printf -- '-%.0s' {1..78}; printf '\n'
    for guid in "${!target_versions[@]}"; do
        target_ver="${target_versions[$guid]}"
        local_ver=$(read_local_gpt_version "/var/lib/samba/sysvol/$REALM_LC/Policies/$guid")
        if [[ "$local_ver" -ge "$target_ver" ]]; then
            status="current"
        elif [[ "$local_ver" -eq 0 ]]; then
            status="MISSING"
        else
            status="STALE (-$((target_ver - local_ver)))"
        fi
        printf '%-40s %10s %10s %s\n' "$guid" "$local_ver" "$target_ver" "$status"
    done
    # Orphan section (local dirs with no AD object).
    if [[ -d "/var/lib/samba/sysvol/$REALM_LC/Policies" ]]; then
        for d in "/var/lib/samba/sysvol/$REALM_LC/Policies/"*/; do
            [[ -d "$d" ]] || continue
            bn=$(basename "$d")
            [[ "$bn" =~ ^\{.*\}$ ]] || continue
            [[ -z "${target_versions[$bn]+set}" ]] || continue
            printf '%-40s %10s %10s %s\n' "$bn" "?" "?" "ORPHAN"
        done
    fi
    exit 0
fi

# --- discover candidate peers (sync mode only) --------------------------------
candidates_raw=()
while IFS=$'\t' read -r tier fqdn; do
    [[ -z "$fqdn" ]] && continue
    candidates_raw+=("${tier}|${fqdn}")
done < <(
    ldb -b "CN=Sites,CN=Configuration,${BASE_DN}" \
        "(objectClass=server)" cn dnsHostName serverReference \
    | awk -v self="$NETBIOS_SELF" '
        # LDAP attribute names are case-insensitive; ldbsearch echoes them
        # in whatever case the schema declared. Normalize the attribute name
        # to lower case for matching, then take the value verbatim.
        function reset() { cn=""; fqdn=""; ref="" }
        BEGIN { reset() }
        /^[Dd][Nn]:/ { reset(); next }
        /^[^:]+:[[:space:]]/ {
            ix = index($0, ":")
            attr = tolower(substr($0, 1, ix - 1))
            val  = substr($0, ix + 2)
            if      (attr == "cn")              cn   = val
            else if (attr == "dnshostname")     fqdn = val
            else if (attr == "serverreference") ref  = val
            next
        }
        /^$/ {
            if (cn != "" && fqdn != "" && toupper(cn) != self)
                printf "%s\t%s\t%s\n", cn, fqdn, ref
            reset()
        }
        END {
            if (cn != "" && fqdn != "" && toupper(cn) != self)
                printf "%s\t%s\t%s\n", cn, fqdn, ref
        }
    ' \
    | while IFS=$'\t' read -r cn fqdn ref; do
        os=$(ldb -b "$ref" "(objectClass=computer)" operatingSystem \
              | awk 'BEGIN{IGNORECASE=1}
                     /^operatingSystem:[[:space:]]/ {
                         ix = index($0, ":")
                         val = substr($0, ix + 2)
                         sub(/\r$/, "", val)
                         print val; exit
                     }')
        case "$os" in
            *Samba*)   tier=2 ;;
            *Windows*) tier=1 ;;
            *)         tier=3 ;;
        esac
        skip=0
        for excl in $EXCLUDE_DCS; do
            [[ "${fqdn,,}" == "${excl,,}" ]] && skip=1
        done
        [[ $skip -eq 1 ]] && continue
        for pref in $PREFERRED_DCS; do
            [[ "${fqdn,,}" == "${pref,,}" ]] && tier=0
        done
        printf '%d\t%s\n' "$tier" "$fqdn"
    done \
    | sort -k1,1n -k2,2
)

candidates=()
for entry in "${candidates_raw[@]}"; do
    tier="${entry%%|*}"
    fqdn="${entry#*|}"
    if probe_reachable "$fqdn"; then
        candidates+=("${tier}|${fqdn}")
        say "candidate: tier=$tier $fqdn (reachable)"
    else
        say "candidate: tier=$tier $fqdn (unreachable, skipped)"
    fi
done

if [[ ${#candidates[@]} -eq 0 ]]; then
    say "no DCs reachable; nothing to do"
    exit 0
fi

# --- pull loop ----------------------------------------------------------------
new_count=0
update_count=0
delete_count=0
skip_count=0
no_source_count=0
any_pulled=0

# Orphan cleanup: local GPO dirs with no matching AD object.
if [[ -d "/var/lib/samba/sysvol/$REALM_LC/Policies" ]]; then
    for d in "/var/lib/samba/sysvol/$REALM_LC/Policies/"*/; do
        [[ -d "$d" ]] || continue
        bn=$(basename "$d")
        [[ "$bn" =~ ^\{.*\}$ ]] || continue
        if [[ -z "${target_versions[$bn]+set}" ]]; then
            say "delete orphan: $bn (no AD object)"
            rm -rf "$d"
            delete_count=$((delete_count + 1))
            any_pulled=1
        fi
    done
fi

for guid in "${!target_versions[@]}"; do
    target_ver="${target_versions[$guid]}"
    local_ver=$(read_local_gpt_version "/var/lib/samba/sysvol/$REALM_LC/Policies/$guid")

    if [[ "$local_ver" -ge "$target_ver" ]]; then
        skip_count=$((skip_count + 1))
        continue
    fi

    say "GPO $guid: local v$local_ver < target v$target_ver"

    chosen_fqdn=""
    chosen_ver=""
    for entry in "${candidates[@]}"; do
        fqdn="${entry#*|}"
        remote_gpt=$(fetch_remote_gpt_version "$fqdn" "$guid")
        # Settled-version gate: any peer that already has GPT version >=
        # what we want has definitionally finished writing it. DFSR (Windows)
        # and this script's own stage-then-swap (Samba peers) both update
        # the GPT.INI Version *after* the on-disk files settle, so seeing
        # remote_gpt >= target_ver is enough to know the peer's content is
        # internally consistent. No need to cross-check the peer's LDAP.
        if [[ "$remote_gpt" -lt "$target_ver" ]]; then
            say "  $fqdn: GPT v$remote_gpt < target v$target_ver, skip"
            continue
        fi
        chosen_fqdn="$fqdn"
        chosen_ver="$remote_gpt"
        break
    done

    if [[ -z "$chosen_fqdn" ]]; then
        say "GPO $guid: no peer has settled v$target_ver yet"
        no_source_count=$((no_source_count + 1))
        continue
    fi

    # Stage-then-swap: never leave the live tree half-written.
    # smbclient mget needs to be `cd <parent>; mget <name>` — passing a
    # path-with-slashes to mget directly produces a silent rc=0 with no
    # files. Use the `cd` form, which mirrors the directory tree under
    # $stage/<guid>/, then rsync that into place.
    stage=$(mktemp -d /tmp/sysvol-stage.XXXXXX)
    if smbclient "//${chosen_fqdn}/sysvol" -P --quiet \
            -c "recurse ON; prompt OFF; cd $REALM_LC/Policies; lcd $stage; mget $guid" \
            >>"$LOGFILE" 2>&1 \
        && [[ -d "$stage/$guid" ]]; then

        dst="/var/lib/samba/sysvol/$REALM_LC/Policies/$guid"
        mkdir -p "$dst"
        if rsync -a --delete --max-delete=100 \
                "$stage/$guid/" "$dst/" >>"$LOGFILE" 2>&1; then
            say "GPO $guid: pulled v$local_ver -> v$chosen_ver from $chosen_fqdn"
            if [[ "$local_ver" -eq 0 ]]; then
                new_count=$((new_count + 1))
            else
                update_count=$((update_count + 1))
            fi
            any_pulled=1
        else
            say "GPO $guid: local rsync into $dst failed"
        fi
    else
        say "GPO $guid: smbclient mget from $chosen_fqdn failed (no $stage/$guid produced)"
    fi
    rm -rf "$stage"
done

# A single whole-tree sysvolreset at the end is cheaper than per-GPO walks
# and matches what samba-tool exposes (no per-path scope).
if [[ $any_pulled -eq 1 ]]; then
    say "running ntacl sysvolreset"
    samba-tool ntacl sysvolreset >>"$LOGFILE" 2>&1 \
        || say "WARN: ntacl sysvolreset failed"
fi

say "done: new=$new_count updated=$update_count deleted=$delete_count current=$skip_count no-source=$no_source_count"
SYNCEOF
chmod +x /usr/local/sbin/sysvol-sync

#===============================================================================
# 21b. DFS-N TARGET-LIST PARSER
#===============================================================================
# msDFS-TargetListv2 is a UTF-16LE-encoded XML document (Windows Server
# 2008+ namespace metadata format), NOT a packed binary blob as the
# MS-DFSNM v1 spec might suggest. Confirmed by inspecting a live blob
# from a WS2025 forest — see docs/DFS-N.md for the truth check.
#
# samba-sconfig dfs-update calls this helper to convert one base64 blob
# (read on stdin) into one tab-separated record per line on stdout:
#
#   <priorityClass>\t<priorityRank>\t<state>\t<unc>
#
# Stdlib only — no extra packages.
#
# Exit codes:
#   0  parsed ≥1 target
#   2  parsed cleanly but found no targets (caller may treat as "skip")
#   3  blob decode or XML parse failure (caller should refuse to apply)
log "Installing samba-dfs-parse-targets..."
cat > /usr/local/sbin/samba-dfs-parse-targets <<'PARSEEOF'
#!/usr/bin/env python3
r"""
samba-dfs-parse-targets — parse a msDFS-TargetListv2 XML blob.

Reads base64 on stdin, writes one TSV record per target on stdout:
    priorityClass  priorityRank  state  unc

Stdlib only. The blob is a UTF-16LE XML document (with optional BOM)
shaped like:

    <?xml version="1.0" encoding="utf-16"?>
    <targets majorVersion="2" minorVersion="0" targetCount="N"
             xmlns="http://schemas.microsoft.com/dfs/2007/03">
      <target state="online" priorityClass="siteCostNormal"
              priorityRank="0">\\SERVER\share</target>
      ...
    </targets>
"""

import base64
import re
import sys
import xml.etree.ElementTree as ET


def main() -> int:
    raw = sys.stdin.read().strip()
    if not raw:
        print("samba-dfs-parse-targets: empty stdin", file=sys.stderr)
        return 3
    try:
        blob = base64.b64decode(raw, validate=False)
    except Exception as exc:
        print(f"samba-dfs-parse-targets: base64 decode failed: {exc}",
              file=sys.stderr)
        return 3
    # Strip UTF-16 BOM if present and pick the right endianness. The
    # default-without-BOM is little-endian per the XML PI's encoding=
    # attribute and matches what WS2025 emits in practice.
    if blob[:2] == b"\xff\xfe":
        endian = "utf-16-le"
        blob = blob[2:]
    elif blob[:2] == b"\xfe\xff":
        endian = "utf-16-be"
        blob = blob[2:]
    else:
        endian = "utf-16-le"
    try:
        text = blob.decode(endian)
    except UnicodeDecodeError as exc:
        print(f"samba-dfs-parse-targets: {endian} decode failed: {exc}",
              file=sys.stderr)
        return 3

    # ElementTree handles namespaces but it's painful to work with element
    # tag names that include the URI. Strip the default xmlns once so we
    # can use plain tag names below. The blob is internal AD metadata, not
    # untrusted XML from the network — no XXE or external-entity surface.
    text = re.sub(r'\sxmlns="[^"]+"', "", text, count=1)

    try:
        root = ET.fromstring(text)
    except ET.ParseError as exc:
        print(f"samba-dfs-parse-targets: XML parse failed: {exc}",
              file=sys.stderr)
        return 3

    if root.tag != "targets":
        print(f"samba-dfs-parse-targets: unexpected root tag {root.tag!r}",
              file=sys.stderr)
        return 3

    out_lines = []
    for t in root.findall("target"):
        unc = (t.text or "").strip()
        if not unc:
            continue
        pclass = t.get("priorityClass", "siteCostNormal")
        prank = t.get("priorityRank", "0")
        state = t.get("state", "online")
        out_lines.append(f"{pclass}\t{prank}\t{state}\t{unc}")

    if not out_lines:
        return 2
    for line in out_lines:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PARSEEOF
chmod 0755 /usr/local/sbin/samba-dfs-parse-targets

# Self-test against a real WS2025-generated blob captured during lab
# validation. Single target, siteCostNormal class, online. Treat any
# failure as a hard image-prep error.
if ! out=$(printf '%s' '//48AD8AeABtAGwAIAB2AGUAcgBzAGkAbwBuAD0AIgAxAC4AMAAiACAAZQBuAGMAbwBkAGkAbgBnAD0AIgB1AHQAZgAtADEANgAiAD8APgANAAoAPAB0AGEAcgBnAGUAdABzACAAbQBhAGoAbwByAFYAZQByAHMAaQBvAG4APQAiADIAIgAgAG0AaQBuAG8AcgBWAGUAcgBzAGkAbwBuAD0AIgAwACIAIAB0AGEAcgBnAGUAdABDAG8AdQBuAHQAPQAiADEAIgAgAHQAbwB0AGEAbABTAHQAcgBpAG4AZwBMAGUAbgBnAHQAaABJAG4AQgB5AHQAZQBzAD0AIgA0ADIAIgAgAHgAbQBsAG4AcwA9ACIAaAB0AHQAcAA6AC8ALwBzAGMAaABlAG0AYQBzAC4AbQBpAGMAcgBvAHMAbwBmAHQALgBjAG8AbQAvAGQAZgBzAC8AMgAwADAANwAvADAAMwAiAD4ADQAKACAAIAA8AHQAYQByAGcAZQB0ACAAcwB0AGEAdABlAD0AIgBvAG4AbABpAG4AZQAiACAAcAByAGkAbwByAGkAdAB5AEMAbABhAHMAcwA9ACIAcwBpAHQAZQBDAG8AcwB0AE4AbwByAG0AYQBsACIAIABwAHIAaQBvAHIAaQB0AHkAUgBhAG4AawA9ACIAMAAiAD4AXABcAFcASQBOAC0AUABSAEkATQBBAFIAWQBcAFAAdQBiAGwAaQBjADwALwB0AGEAcgBnAGUAdAA+AA0ACgA8AC8AdABhAHIAZwBlAHQAcwA+AA==' \
        | /usr/local/sbin/samba-dfs-parse-targets); then
    err "samba-dfs-parse-targets self-test failed (rc=$?)"; exit 1
fi
expected=$'siteCostNormal\t0\tonline\t\\\\WIN-PRIMARY\\Public'
if [[ "$out" != "$expected" ]]; then
    err "samba-dfs-parse-targets self-test mismatch:\n  got: $out\n  want: $expected"
    exit 1
fi
log "  samba-dfs-parse-targets self-test passed"

#===============================================================================
# 22. FIRST-BOOT HOST INTEGRATION
#===============================================================================
# samba-firstboot detects which hypervisor we're running on AT FIRST BOOT
# (not at image-prep time), installs the matching guest agent offline from
# /var/cache/samba-appliance/vmtools/, prints host-specific recommendations,
# and disables itself. The marker file /var/lib/samba-firstboot.done makes
# subsequent boots a no-op.
log "Installing samba-firstboot helper + service..."

cat > /usr/local/sbin/samba-firstboot <<'FBEOF'
#!/usr/bin/env bash
#
# samba-firstboot — runs once on the first boot of a deployed Samba AD DC
# appliance. Detects the actual hypervisor (which is usually NOT the same as
# the one the image was mastered on), installs the matching guest agent from
# /var/cache/samba-appliance/vmtools/ offline, deletes the unused caches,
# prints recommended VM hardware, and disables itself.

set -u -o pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

APPCORE_LIBS=/usr/local/lib/appliance-core
if [[ -f "$APPCORE_LIBS/detect-net.sh" ]]; then
    # shellcheck disable=SC1091
    source "$APPCORE_LIBS/detect-net.sh"
fi

LOGFILE="/var/log/samba-firstboot.log"
MARKER="/var/lib/samba-firstboot.done"
MOTD="/etc/motd.d/01-samba-firstboot"
CACHE="/var/cache/samba-appliance/vmtools"
MANIFEST="$CACHE/manifest"

mkdir -p /var/lib /etc/motd.d "$(dirname "$LOGFILE")"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOGFILE"; }

if [[ -f "$MARKER" ]]; then
    log "samba-firstboot already complete (marker present); nothing to do"
    exit 0
fi

VIRT=$(systemd-detect-virt 2>/dev/null || echo "none")
log "host environment: $VIRT"

# Look up the package list for this virt-type from the manifest.
PKG_LIST=""
if [[ -f "$MANIFEST" ]]; then
    PKG_LIST=$(awk -F= -v v="$VIRT" 'NF>=2 && $1==v {sub(/^[^=]+=/, "", $0); print; exit}' "$MANIFEST")
fi

# Azure runs on Hyper-V, so systemd-detect-virt reports 'microsoft'. Tell
# them apart by the chassis-asset-tag DMI string Azure sets to a fixed
# value. When matched, augment the install list with cloud-init so the
# Azure IMDS injection pathway (SSH keys, hostname, user-data) works.
# walinuxagent's old responsibilities are largely covered by cloud-init
# on modern Debian; we don't try to bundle walinuxagent itself because
# it's not in Trixie main.
AZURE_CHASSIS_TAG="7783-7084-3265-9085-8269-3286-77"
if [[ "$VIRT" == "microsoft" ]] && \
   [[ -r /sys/class/dmi/id/chassis_asset_tag ]] && \
   [[ "$(cat /sys/class/dmi/id/chassis_asset_tag 2>/dev/null)" == "$AZURE_CHASSIS_TAG" ]]; then
    log "Azure detected via DMI chassis-asset-tag; adding cloud-init"
    PKG_LIST="$PKG_LIST cloud-init"
fi

# Per-package systemd unit map. Empty means "no service to enable".
service_units_for() {
    case "$1" in
        qemu-guest-agent)  echo "qemu-guest-agent" ;;
        open-vm-tools)     echo "open-vm-tools" ;;
        # Trixie's hyperv-daemons ships hv-kvp-daemon + hv-vss-daemon as units.
        # The historical hv-fcopy-daemon was retired upstream — file copy now
        # happens via the in-kernel hv_fcopy module.
        hyperv-daemons)    echo "hv-kvp-daemon hv-vss-daemon" ;;
        # cloud-init enables its own 4-stage systemd units via postinst. We
        # don't enable here; on next boot cloud-init runs naturally.
        cloud-init)        echo "" ;;
        # cloud-guest-utils is just CLI tools (growpart etc.); no services.
        cloud-guest-utils) echo "" ;;
        *)                 echo "" ;;
    esac
}

INSTALLED_NOTE=""
INSTALLED_PKGS=""
FAILED_PKGS=""

if [[ -z "$PKG_LIST" ]]; then
    INSTALLED_NOTE="No guest-agent or cloud-helper package staged for '$VIRT'.\nThe DC will run without host-side integration; chrony handles time,\nACPI handles graceful shutdown — both work without an agent. Install\nany of /var/cache/samba-appliance/vmtools/<pkg>/*.deb by hand if you\nwant management-plane integration."
    log "$INSTALLED_NOTE"
else
    log "installing for $VIRT: $PKG_LIST"
    for pkg in $PKG_LIST; do
        deb_dir="$CACHE/$pkg"
        if [[ ! -d "$deb_dir" ]] || ! compgen -G "$deb_dir/*.deb" >/dev/null; then
            log "  WARN: $pkg has no .deb files in cache (skipping)"
            FAILED_PKGS="$FAILED_PKGS $pkg"
            continue
        fi
        log "  dpkg -i $pkg (offline from $deb_dir)"
        if dpkg -i "$deb_dir"/*.deb >>"$LOGFILE" 2>&1; then
            INSTALLED_PKGS="$INSTALLED_PKGS $pkg"
        else
            log "    ERROR: dpkg -i of $pkg failed; see $LOGFILE"
            FAILED_PKGS="$FAILED_PKGS $pkg"
        fi
    done

    systemctl daemon-reload || true

    for pkg in $INSTALLED_PKGS; do
        for svc in $(service_units_for "$pkg"); do
            if systemctl enable --now "$svc" >>"$LOGFILE" 2>&1; then
                log "  enabled+started: $svc ($pkg)"
            else
                log "  WARN: could not start $svc (from $pkg)"
            fi
        done
    done

    if [[ -n "$INSTALLED_PKGS" ]]; then
        INSTALLED_NOTE="Installed:$INSTALLED_PKGS"
        [[ -n "$FAILED_PKGS" ]] && INSTALLED_NOTE+=$'\n'"Failed:   $FAILED_PKGS (see $LOGFILE)"
    elif [[ -n "$FAILED_PKGS" ]]; then
        INSTALLED_NOTE="ERROR: nothing installed; failed:$FAILED_PKGS"
        log "$INSTALLED_NOTE"
    fi

    # If we just installed cloud-init, prompt the user to reboot. cloud-init
    # has a 4-stage state machine that's tied into systemd's boot sequence;
    # running it now from late in the current boot won't pick up everything
    # the way an early-boot run does. A reboot is the path of least surprise.
    if echo " $INSTALLED_PKGS " | grep -q ' cloud-init '; then
        INSTALLED_NOTE+=$'\n'"NOTE: reboot once to let cloud-init run from early boot and apply"
        INSTALLED_NOTE+=$'\n'"      IMDS data (SSH keys, hostname) from your cloud platform."
    fi
fi

# Host-specific recommendations. Echoed to log AND written to a motd snippet
# so they show up at every SSH login until an admin removes the file.
read -r -d '' RECS <<RECEOF || true
=== Recommended VM hardware/config for $VIRT ===
RECEOF

case "$VIRT" in
    kvm|qemu)
        RECS+=$'\n'"  Hypervisor: KVM/QEMU (Proxmox, libvirt, oVirt, ...)"
        RECS+=$'\n'"  vCPU:       2+ (Skylake-Client+ or host-passthrough for AES-NI)"
        RECS+=$'\n'"  RAM:        2 GiB minimum, 4 GiB+ for active DCs"
        RECS+=$'\n'"  Disk:       virtio-blk or virtio-scsi (NOT IDE/SATA)"
        RECS+=$'\n'"  NIC:        virtio-net (NOT e1000/rtl8139)"
        RECS+=$'\n'"  Agent:      qemu-guest-agent (this script just installed it)"
        RECS+=$'\n'"  Time:       enable virtio-rtc; chrony is authoritative for AD time"
        ;;
    vmware)
        RECS+=$'\n'"  Hypervisor: VMware (ESXi / vCenter / Workstation / Fusion)"
        RECS+=$'\n'"  vCPU:       2+, expose AES-NI in CPU/MMU virt settings"
        RECS+=$'\n'"  RAM:        2 GiB minimum, 4 GiB+ for active DCs (no ballooning)"
        RECS+=$'\n'"  Disk:       Paravirtual SCSI (PVSCSI) controller"
        RECS+=$'\n'"  NIC:        vmxnet3 (NOT e1000)"
        RECS+=$'\n'"  Agent:      open-vm-tools (this script just installed it)"
        RECS+=$'\n'"  Time:       disable VMware Tools time-sync; chrony manages domain time"
        ;;
    microsoft)
        if [[ "$(cat /sys/class/dmi/id/chassis_asset_tag 2>/dev/null)" == "$AZURE_CHASSIS_TAG" ]]; then
            RECS+=$'\n'"  Platform:   Microsoft Azure (Hyper-V-backed)"
            RECS+=$'\n'"  vCPU:       2+, AES-NI exposed (default on Standard SKUs)"
            RECS+=$'\n'"  RAM:        2 GiB+ (e.g. Standard_B2s for tests, _D2s_v5 for prod)"
            RECS+=$'\n'"  Disk:       Premium SSD; use a dedicated managed disk for /var/lib/samba"
            RECS+=$'\n'"  NIC:        Accelerated Networking ON if SKU supports it"
            RECS+=$'\n'"  Agents:     hyperv-daemons + cloud-init (just installed)"
            RECS+=$'\n'"  Time:       chrony is authoritative; disable Azure time-sync if it competes"
            RECS+=$'\n'"  Backups:    Azure Backup VM-level snapshots are application-consistent"
            RECS+=$'\n'"              via VSS — generally OK for an AD DC, but verify each release"
        else
            RECS+=$'\n'"  Hypervisor: Microsoft Hyper-V (on-prem)"
            RECS+=$'\n'"  Generation: 2 (UEFI). Disable Secure Boot (cloud-image bootloader)"
            RECS+=$'\n'"  vCPU:       2+, virtualization extensions exposed"
            RECS+=$'\n'"  RAM:        2 GiB+ STATIC; do not use Dynamic Memory on AD DCs"
            RECS+=$'\n'"  Disk:       SCSI controller (NOT IDE)"
            RECS+=$'\n'"  NIC:        Hyper-V synthetic adapter (default for Gen2)"
            RECS+=$'\n'"  Integration: enable Time Sync, Heartbeat, Guest Service Interface"
            RECS+=$'\n'"  Agent:      hyperv-daemons (this script just installed it)"
            RECS+=$'\n'"  Checkpoints: prefer offline (Standard) checkpoints over Production"
            RECS+=$'\n'"               for AD DCs — VSS-quiesced live snapshots interact"
            RECS+=$'\n'"               poorly with USN replication semantics."
        fi
        ;;
    amazon)
        RECS+=$'\n'"  Platform:   Amazon EC2 (Nitro)"
        RECS+=$'\n'"  Instance:   M-class or T-class with at least 2 vCPU / 2 GiB"
        RECS+=$'\n'"  Disk:       gp3 EBS for the root volume; consider separate volume for /var/lib/samba"
        RECS+=$'\n'"  NIC:        ENA driver (kernel built-in)"
        RECS+=$'\n'"  Agents:     qemu-guest-agent + cloud-init + cloud-guest-utils (installed)"
        RECS+=$'\n'"  Networking: place DCs in private subnets with VPC peering or AD-replication NACLs"
        RECS+=$'\n'"  Backups:    EBS snapshots are crash-consistent — schedule with care for an AD DC"
        ;;
    xen)
        RECS+=$'\n'"  Hypervisor: Xen / Citrix Hypervisor / XCP-ng"
        RECS+=$'\n'"  vCPU:       2+, expose AES-NI"
        RECS+=$'\n'"  RAM:        2 GiB+, no ballooning for AD DCs"
        RECS+=$'\n'"  Disk:       PVHVM virtual disk"
        RECS+=$'\n'"  NIC:        netfront (paravirtualized)"
        RECS+=$'\n'"  Agents:     qemu-guest-agent + xe-guest-utilities (installed)"
        RECS+=$'\n'"  Time:       sync via Xen virtio-rtc; chrony authoritative for AD"
        ;;
    oracle)
        RECS+=$'\n'"  Hypervisor: Oracle VirtualBox"
        RECS+=$'\n'"  No headless guest-agent .deb is staged. If you want VBoxClient"
        RECS+=$'\n'"  features (clipboard, file integration), install"
        RECS+=$'\n'"  virtualbox-guest-utils manually (~30 MB of X dependencies)."
        ;;
    none)
        RECS+=$'\n'"  Bare-metal install detected — no virtualization-specific advice."
        RECS+=$'\n'"  Make sure chrony has reachable upstream NTP, the NIC is wired,"
        RECS+=$'\n'"  and the BIOS clock is sane."
        ;;
    *)
        RECS+=$'\n'"  Unknown environment '$VIRT'. No specific recommendations."
        RECS+=$'\n'"  AD DC operation does not require a guest agent — run it without."
        ;;
esac

log ""
printf '%s\n' "$RECS" | tee -a "$LOGFILE"

# Image-freshness check: how stale is this image vs the upstream Debian
# archive? Useful for deployers who imported an OVA built months ago and
# want to know whether to apt-get upgrade before putting the DC into
# production. Skipped silently if no default route (offline environment
# or DHCP didn't give us one).
log ""
log "checking image freshness (apt-get update + upgradable count)..."
APT_FRESHNESS=""
apt_update_with_lock_retry() {
    local attempt
    for attempt in $(seq 1 12); do
        if apt-get update -qq >>"$LOGFILE" 2>&1; then
            return 0
        fi
        if tail -n 6 "$LOGFILE" \
            | grep -qE 'Could not get lock|Unable to lock'; then
            log "  apt lock busy; retrying freshness check (${attempt}/12)"
            sleep 5
        else
            return 1
        fi
    done
    return 1
}
# Wait up to 20s for default route to settle (netplan/dhcp may still be
# negotiating right after the agent install above).
for _ in $(seq 1 10); do
    [[ -n "$(ip route show default 2>/dev/null)" ]] && break
    sleep 2
done
if [[ -z "$(ip route show default 2>/dev/null)" ]]; then
    APT_FRESHNESS="apt: offline (no default route) — freshness check skipped"
elif apt_update_with_lock_retry; then
    # Use --simulate to count what apt would ACTUALLY install. Plain
    # `apt list --upgradable` includes phased-rollout packages (apt 2.x
    # feature: held back per-machine until the rollout completes), and
    # those keep showing as pending forever even after upgrade because
    # they're never actually installed by full-upgrade. --simulate
    # reflects what the operator can act on right now.
    sim=$(apt-get --simulate -qq dist-upgrade 2>/dev/null) || sim=""
    upg=$(grep -c '^Inst ' <<< "$sim" || true)
    sec=$(grep -c '^Inst .*-security' <<< "$sim" || true)
    upg="${upg:-0}"; sec="${sec:-0}"
    if [[ "$upg" -eq 0 ]]; then
        APT_FRESHNESS="apt: image is current (0 upgrades pending)"
    else
        # Kernel and other held-back packages require dist-upgrade (installs new
        # packages); plain upgrade refuses to do so and silently skips them.
        if grep -q "kept back" <<< "$sim"; then
            apt_cmd="sudo apt-get dist-upgrade"
        else
            apt_cmd="sudo apt-get upgrade"
        fi
        APT_FRESHNESS="apt: ${upg} upgrades pending (${sec} security-marked); review with 'apt list --upgradable', apply with '${apt_cmd}'"
    fi
else
    APT_FRESHNESS="apt: index refresh failed — see $LOGFILE"
fi
log "  $APT_FRESHNESS"

# Network-environment detection: probes that help samba-init present
# smart defaults to the operator (instead of asking them to type values
# the network already knows).
#
# Findings land in /var/lib/samba-init-detected.env, refreshed on each
# firstboot cycle. samba-init reads it on every menu render so the data
# stays in sync with the current network even if the operator switches
# from DHCP to static and back.
log ""
log "detecting network-environment hints..."
DETECT_FILE=/var/lib/samba-init-detected.env
mkdir -p /var/lib

# appliance-core owns all generic network probes, cache freshness, and
# effective-domain source attribution.
if ! command -v appcore_detect_net_init >/dev/null 2>&1; then
    log "ERROR: appliance-core detect-net.sh is unavailable"
    exit 1
fi
appcore_detect_net_init
appcore_detect_net_write_cache "$DETECT_FILE"

# Samba's only extension is AD-DC discovery for the canonical domain
# candidates. Persist it alongside the generic context.
samba_det_ad_dc="" samba_det_ad_realm=""
for d in "$APPCORE_DET_DHCP_DOMAIN" "$APPCORE_DET_PTR_DOMAIN"; do
    [[ -z "$d" ]] && continue
    samba_det_ad_dc=$(timeout 5 dig +short -t SRV "_ldap._tcp.${d}" 2>/dev/null \
                 | awk 'NR==1 {sub(/\.$/,"",$4); print $4}')
    if [[ -n "$samba_det_ad_dc" ]]; then
        samba_det_ad_realm="$d"
        break
    fi
done

cat >> "$DETECT_FILE" <<DETEOF
SAMBA_DET_AD_DC="${samba_det_ad_dc:-}"
SAMBA_DET_AD_REALM="${samba_det_ad_realm:-}"
DETEOF
chmod 644 "$DETECT_FILE"
log "  IP: ${APPCORE_DET_IP:-?}  gateway: ${APPCORE_DET_GATEWAY:-?}"
log "  DHCP-DNS: ${APPCORE_DET_DHCP_DNS:-(none)}  DHCP-domain: ${APPCORE_DET_DHCP_DOMAIN:-(none)}"
log "  PTR: ${APPCORE_DET_PTR_FQDN:-(none)}  -> short=${APPCORE_DET_PTR_NAME:-?}  domain=${APPCORE_DET_PTR_DOMAIN:-(none)}"
log "  effective realm: ${APPCORE_DET_EFFECTIVE_DOMAIN:-(none)} (${APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE:-no source})  AD-DC: ${samba_det_ad_dc:-(none)} (in ${samba_det_ad_realm:-?})"

# Write the motd snippet — visible at every SSH login until removed.
{
    echo
    echo "=== First-boot host detection (Samba AD DC) ==="
    echo "Detected: $VIRT"
    printf '%s\n' "$INSTALLED_NOTE" | sed 's/^/  /'
    printf '%s\n' "$RECS"
    echo
    echo "Image freshness:"
    echo "  $APT_FRESHNESS"
    echo
    echo "(Remove $MOTD to silence this banner.)"
    echo
} > "$MOTD"

# Cleanup: remove caches for packages we did not install, keep the ones we
# did (handy for re-running dpkg -i if something goes sideways) plus the
# manifest. Builds a space-padded keep-list and a substring match.
log ""
log "cleaning up unused guest-agent / cloud-helper caches..."
KEEP=" $(echo "$INSTALLED_PKGS" | xargs) "
shopt -s nullglob
for d in "$CACHE"/*/; do
    name=$(basename "$d")
    if [[ "$KEEP" != *" $name "* ]]; then
        log "  removing $d"
        rm -rf "$d"
    fi
done
shopt -u nullglob

# Mark done; disable the unit so subsequent boots are clean.
touch "$MARKER"
log "samba-firstboot complete; marker at $MARKER"
systemctl disable samba-firstboot.service >>"$LOGFILE" 2>&1 || true
FBEOF
chmod +x /usr/local/sbin/samba-firstboot

cat > /etc/systemd/system/samba-firstboot.service <<'UEOF'
[Unit]
Description=Samba AD DC Appliance first-boot host integration
ConditionPathExists=!/var/lib/samba-firstboot.done
After=local-fs.target network-online.target
Wants=network-online.target
# Run before samba-ad-dc so the guest agent is up before any AD traffic.
# samba-ad-dc is masked at image-prep time and only enabled by samba-sconfig
# after a join/provision, so this ordering is mostly defensive.
Before=samba-ad-dc.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/samba-firstboot
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UEOF

systemctl daemon-reload
systemctl enable samba-firstboot.service

#===============================================================================
# 23. CONSOLE INITIAL-SETUP WIZARD (TTY1)
#===============================================================================
# When the appliance lands somewhere DHCP doesn't work, or the operator
# doesn't have the SSH key the master was built with, the only access path
# is the hypervisor's console. samba-init is a whiptail-driven setup wizard
# that takes over TTY1 (via getty autologin) on every boot until the
# operator marks setup complete. It can configure static IP, change the
# default password, paste an SSH authorized_keys entry, and rename the
# host. After it writes /var/lib/samba-init.done, TTY1 falls back to a
# normal login prompt on subsequent boots.
log "Installing samba-init console wizard + TTY1 autologin..."

cat > /usr/local/sbin/samba-init <<'INITEOF'
#!/usr/bin/env bash
#
# samba-init — TTY1-resident console setup wizard. Runs as 'debadmin' via
# autologin; uses passwordless sudo (preconfigured at master build) for
# system changes. Loops a whiptail menu until the operator picks
# "Mark setup complete and proceed to login".
#
# State files:
#   /var/lib/samba-init.done                -> setup acknowledged; wizard
#                                              skipped on subsequent boots
#   /var/lib/samba-init-default-password    -> debadmin still has the
#                                              factory default password;
#                                              the wizard refuses to mark
#                                              complete while this exists

set -u

# Source shared appliance-core libs vendored by prepare-image.sh §18b.
# Sentinel-guarded so this is a no-op if already loaded by an earlier
# script in the same shell; falls through silently when the libs are
# absent (older images that predate the vendoring).
APPCORE_LIBS=/usr/local/lib/appliance-core
if [[ -d "$APPCORE_LIBS" ]]; then
    for _lib in apt-helpers detect-net identity tui hostname netconfig timezone; do
        [[ -f "$APPCORE_LIBS/${_lib}.sh" ]] && source "$APPCORE_LIBS/${_lib}.sh"
    done
    unset _lib
fi

MARKER=/var/lib/samba-init.done
DEFAULT_PWD_MARKER=/var/lib/samba-init-default-password
GETTY_DROPIN=/etc/systemd/system/getty@tty1.service.d/samba-init.conf
SELF_USER=$(id -un)

# If setup is already complete, drop straight to a normal login shell.
# This is defensive — the systemd drop-in is supposed to be removed when
# setup completes, so we shouldn't normally hit this branch.
if [[ -f "$MARKER" ]]; then
    exec /bin/bash --login
fi

# Geometry constants.
WT_HEIGHT=20
WT_WIDTH=72
WT_MENU=10

# ----------------------------------------------------------------------------
# Detection: refresh from /var/lib/samba-init-detected.env on every menu
# render. samba-firstboot writes that file once at first boot; we re-read
# IP + gateway live each render so they stay current after the operator
# changes network mode through the wizard.
# ----------------------------------------------------------------------------
DETECT_FILE=/var/lib/samba-init-detected.env

load_detect_env() {
    DET_IP="" DET_GATEWAY="" DET_DHCP_DNS="" DET_DHCP_DOMAIN=""
    DET_PTR_FQDN="" DET_PTR_NAME="" DET_PTR_DOMAIN=""
    DET_EFFECTIVE_DOMAIN="" DET_AD_DC="" DET_AD_REALM=""
    SAMBA_DET_AD_DC="" SAMBA_DET_AD_REALM=""
    if [[ -f "$DETECT_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$DETECT_FILE"
    fi
    if command -v appcore_detect_net_init >/dev/null 2>&1; then
        appcore_detect_net_init "$DETECT_FILE" >/dev/null 2>&1 || true
        DET_IP="${APPCORE_DET_IP:-}"
        DET_GATEWAY="${APPCORE_DET_GATEWAY:-}"
        DET_DHCP_DNS="${APPCORE_DET_DHCP_DNS:-}"
        DET_DHCP_DOMAIN="${APPCORE_DET_DHCP_DOMAIN:-}"
        DET_PTR_FQDN="${APPCORE_DET_PTR_FQDN:-}"
        DET_PTR_NAME="${APPCORE_DET_PTR_NAME:-}"
        DET_PTR_DOMAIN="${APPCORE_DET_PTR_DOMAIN:-}"
        DET_EFFECTIVE_DOMAIN="${APPCORE_DET_EFFECTIVE_DOMAIN:-}"
    fi
    if [[ -n "$SAMBA_DET_AD_REALM" &&
          "${SAMBA_DET_AD_REALM,,}" == "${DET_EFFECTIVE_DOMAIN,,}" ]]; then
        DET_AD_DC="$SAMBA_DET_AD_DC"
        DET_AD_REALM="$SAMBA_DET_AD_REALM"
    fi
}

count_upgrades() {
    # Delegate to appliance-core when vendored; the lib's
    # implementation is the canonical phased-rollout-aware counter.
    # Fallback retained for older images that predate vendoring.
    if command -v appcore_apt_count_upgrades >/dev/null 2>&1; then
        appcore_apt_count_upgrades
        return
    fi
    if [[ -z "$(ip route show default 2>/dev/null)" ]]; then
        echo "0 0"; return
    fi
    local sim upg sec
    sim=$(apt-get --simulate -qq dist-upgrade 2>/dev/null) || sim=""
    upg=$(grep -c '^Inst ' <<< "$sim" || true)
    sec=$(grep -c '^Inst .*-security' <<< "$sim" || true)
    echo "${upg:-0} ${sec:-0}"
}

# ----------------------------------------------------------------------------
# Existing whiptail helper functions — kept verbatim except where the TUI
# step uses detected values as pre-filled defaults (set_hostname suggests
# the PTR if we still have the build-time hostname; config_network static
# mode pre-fills from the live DHCP lease).
# ----------------------------------------------------------------------------
show_status() {
    {
        echo "Hostname: $(hostnamectl hostname 2>/dev/null || hostname)"
        echo
        echo "Network interfaces:"
        ip -br addr show | sed 's/^/  /'
        echo
        echo "Default route:"
        ip route show default | sed 's/^/  /'
        [[ -z "$(ip route show default)" ]] && echo "  (none — no default gateway)"
        echo
        echo "DNS resolvers (resolvectl):"
        resolvectl dns 2>/dev/null | sed 's/^/  /' || echo "  (none)"
        echo
        echo "Setup state:"
        echo "  default password active: $([[ -f $DEFAULT_PWD_MARKER ]] && echo yes || echo no)"
        echo "  samba-firstboot done   : $([[ -f /var/lib/samba-firstboot.done ]] && echo yes || echo no)"
        echo "  AD DC service          : $(systemctl is-active samba-ad-dc 2>/dev/null || echo not-running)"
    } > /tmp/samba-init-status.$$
    whiptail --title "Network & setup status" --scrolltext \
        --textbox /tmp/samba-init-status.$$ "$WT_HEIGHT" "$WT_WIDTH"
    rm -f /tmp/samba-init-status.$$
}

config_network() {
    # Delegate to appliance-core's netconfig.sh. The lib's
    # change_tui_single_nic offers DHCP / pin-current-lease /
    # custom-static / cancel, validates inputs via identity.sh,
    # writes proper netplan, applies, and shows the result via the
    # sized-textbox renderer (no clipping on long output).
    if command -v appcore_netconfig_change_tui_single_nic >/dev/null 2>&1; then
        load_detect_env
        sudo bash -c '
            source /usr/local/lib/appliance-core/netconfig.sh
            appcore_netconfig_change_tui_single_nic \
                /etc/netplan/60-samba-init.yaml \
                "e*" \
                "$1"
        ' bash "$DET_DHCP_DNS"
        return
    fi
    # Fallback for older images without the lib.
    whiptail --title "Network configuration" --msgbox \
        "appliance-core netconfig lib missing.\nRebuild via lab/build-fresh-base.sh." \
        10 60
}

change_password() {
    local p1 p2
    p1=$(whiptail --passwordbox "New password for ${SELF_USER} (min 8 chars):" 10 "$WT_WIDTH" 3>&1 1>&2 2>&3) || return
    [[ ${#p1} -lt 8 ]] && { whiptail --msgbox "Min 8 characters." 8 50; return; }
    p2=$(whiptail --passwordbox "Confirm password:" 10 "$WT_WIDTH" 3>&1 1>&2 2>&3) || return
    [[ "$p1" == "$p2" ]] || { whiptail --msgbox "Passwords don't match." 8 50; return; }

    if echo "${SELF_USER}:${p1}" | sudo chpasswd; then
        sudo rm -f "$DEFAULT_PWD_MARKER"
        whiptail --msgbox "Password updated for ${SELF_USER}.\n\nThe default-password marker is gone; you can now mark setup complete." 11 "$WT_WIDTH"
    else
        whiptail --msgbox "chpasswd failed; password not changed." 8 50
    fi
}

ssh_key_console_hint() {
    local virt
    virt=$(systemd-detect-virt 2>/dev/null || true)
    case "$virt" in
        qemu|kvm)
            printf '%s' \
                "Web noVNC console (including Synology VMM): normal clipboard paste does not work in this text screen.\n\nOptional: in Chrome, install \"KVM Console Paste\" from the Chrome Web Store, allow it for this VMM site, then use it to send the key.\n\nOtherwise Cancel and choose manual entry."
            ;;
        *)
            printf '%s' \
                "Use the virtual console's clipboard control if available.\nIf paste fails, Cancel and use manual entry."
            ;;
    esac
}

read_pasted_ssh_key() {
    local hint key
    hint=$(ssh_key_console_hint)
    key=$(whiptail --title "Paste SSH public key" --inputbox \
        "Paste one complete public-key line into the entry field, then select OK.\n\nExpected form:\nssh-ed25519 AAAA... optional-comment\n\n${hint}" \
        20 "$WT_WIDTH" 3>&1 1>&2 2>&3) || return 1
    [[ -n "$key" ]] || return 1
    printf '%s' "$key"
}

read_typed_ed25519_key() {
    local body="" chunk part start end
    for part in 1 2 3 4; do
        start=$(( (part - 1) * 17 + 1 ))
        end=$(( part * 17 ))
        while true; do
            chunk=$(whiptail --title "Type Ed25519 key — part ${part} of 4" \
                --inputbox \
                "Type characters ${start}-${end} of the 68-character text after \"ssh-ed25519 \".\n\nRuler: 12345678901234567\nEnter exactly 17 characters. Do not type spaces or the optional comment.\n\nCompleted: ${#body}/68 characters" \
                15 "$WT_WIDTH" 3>&1 1>&2 2>&3) || return 1
            if [[ "$chunk" =~ ^[A-Za-z0-9+/]{17}$ ]]; then
                break
            fi
            whiptail --msgbox \
                "That part must contain exactly 17 base64 characters:\nA-Z, a-z, 0-9, +, or /." \
                10 "$WT_WIDTH"
        done
        body+="$chunk"
    done
    printf 'ssh-ed25519 %s' "$body"
}

confirm_ssh_public_key() {
    local key="$1" key_info tmp
    tmp=$(mktemp /tmp/samba-init-key.XXXXXX) || {
        whiptail --msgbox "Could not create a temporary file; key not added." 8 "$WT_WIDTH"
        return 1
    }
    printf '%s\n' "$key" > "$tmp"
    if ! key_info=$(ssh-keygen -lf "$tmp" 2>/dev/null); then
        rm -f "$tmp"
        whiptail --msgbox \
            "The completed text is not a valid SSH public key.\nCheck it against the original and try again." \
            10 "$WT_WIDTH"
        return 1
    fi
    rm -f "$tmp"
    whiptail --title "Confirm SSH public key" --yesno \
        "Valid key fingerprint:\n\n${key_info}\n\nAdd this key for ${SELF_USER}?" \
        13 "$WT_WIDTH"
}

add_ssh_key() {
    local key method
    method=$(whiptail --title "Add SSH public key" --menu \
        "Choose how to enter the key." 14 "$WT_WIDTH" 3 \
        "P" "Paste one complete public-key line" \
        "T" "Type an Ed25519 key in four short parts" \
        "B" "Back" \
        3>&1 1>&2 2>&3) || return
    case "$method" in
        P) key=$(read_pasted_ssh_key) || return ;;
        T) key=$(read_typed_ed25519_key) || return ;;
        *) return ;;
    esac

    case "$key" in
        ssh-rsa\ *|ssh-ed25519\ *|ecdsa-*\ *|sk-*) ;;
        *) whiptail --msgbox "That doesn't look like an SSH public key (no algorithm prefix)." 8 70; return ;;
    esac
    confirm_ssh_public_key "$key" || return

    local auth_file home
    home=$(getent passwd "$SELF_USER" | cut -d: -f6)
    auth_file="$home/.ssh/authorized_keys"
    sudo install -d -o "$SELF_USER" -g "$SELF_USER" -m 0700 "$home/.ssh"
    if sudo test -f "$auth_file" && sudo grep -qxF -- "$key" "$auth_file"; then
        whiptail --msgbox "That key is already authorized for ${SELF_USER}." 8 "$WT_WIDTH"
        return
    fi
    if printf '%s\n' "$key" | sudo tee -a "$auth_file" >/dev/null; then
        sudo chown "$SELF_USER:$SELF_USER" "$auth_file"
        sudo chmod 0600 "$auth_file"
        whiptail --msgbox "Key added. SSH login as ${SELF_USER} will accept it." 9 "$WT_WIDTH"
    else
        whiptail --msgbox "Failed to write authorized_keys." 8 50
    fi
}

set_hostname() {
    load_detect_env
    local cur new prefill
    cur=$(hostnamectl hostname 2>/dev/null || hostname)
    prefill="$cur"
    # If reverse DNS gave us a name and we're still on the build-time
    # default 'samba-dc1', suggest the PTR — likely the admin pre-staged
    # this hostname against the IP we got.
    if [[ -n "$DET_PTR_NAME" && "$cur" == "samba-dc1" ]]; then
        prefill="$DET_PTR_NAME"
    fi
    new=$(whiptail --inputbox "New hostname (short name, no FQDN; max 15 chars).\n\nDetected PTR for our IP: ${DET_PTR_NAME:-(none)}" 12 "$WT_WIDTH" "$prefill" 3>&1 1>&2 2>&3) || return
    [[ -n "$new" ]] || return
    [[ "$new" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,14}$ ]] || {
        whiptail --msgbox "Hostname must start with a letter, only [a-zA-Z0-9-], 1-15 chars (NetBIOS limit)." 9 "$WT_WIDTH"
        return
    }
    sudo hostnamectl set-hostname "$new"
    sudo sed -i "s/\\b${cur}\\b/${new}/g" /etc/hosts
    whiptail --msgbox "Hostname is now ${new}. Reboot recommended after marking setup complete." 9 "$WT_WIDTH"
}

show_firstboot_log() {
    if [[ -f /var/log/samba-firstboot.log ]]; then
        whiptail --title "/var/log/samba-firstboot.log" --scrolltext \
            --textbox /var/log/samba-firstboot.log "$WT_HEIGHT" "$WT_WIDTH"
    else
        whiptail --msgbox "No samba-firstboot log yet (firstboot may not have run)." 8 60
    fi
}

set_timezone() {
    local cur suggested="" failure="" prefill new
    cur=$(timedatectl show --property=Timezone --value 2>/dev/null || echo Etc/UTC)
    cur="${cur:-Etc/UTC}"
    if command -v appcore_timezone_suggest >/dev/null 2>&1; then
        if appcore_timezone_suggest >/dev/null; then
            suggested="$APPCORE_TIMEZONE_SUGGESTION"
        else
            failure="$APPCORE_TIMEZONE_ERROR"
        fi
    else
        failure="Automatic suggestion unavailable on this image."
    fi
    prefill="${suggested:-$cur}"
    local prompt="Current timezone: ${cur}"
    if [[ -n "$suggested" ]]; then
        prompt+="\nDetected suggestion: ${suggested}"
    else
        prompt+="\n${failure}"
    fi
    prompt+="\n\nEnter Region/City. Examples:\n  America/Los_Angeles  Europe/London  Asia/Tokyo  Etc/UTC"
    new=$(whiptail --inputbox "$prompt" 14 "$WT_WIDTH" "$prefill" 3>&1 1>&2 2>&3) || return
    [[ -n "$new" ]] || return
    if timedatectl list-timezones 2>/dev/null | grep -qx "$new"; then
        sudo timedatectl set-timezone "$new"
        whiptail --msgbox "Timezone is now: $(timedatectl show --property=Timezone --value)\n\nLocal time: $(date)" 11 "$WT_WIDTH"
    else
        whiptail --msgbox "Unknown timezone: $new\n\nUse 'Region/City' as listed by:\n  timedatectl list-timezones" 11 "$WT_WIDTH"
    fi
}

mark_done_tui() {
    if [[ -f "$DEFAULT_PWD_MARKER" ]]; then
        whiptail --msgbox "Change the ${SELF_USER} password before marking setup complete.\n\nThe default password is documented and trivially findable." 11 "$WT_WIDTH"
        return
    fi
    whiptail --yesno "Mark initial setup complete?\n\n  - This wizard will not run on subsequent boots.\n  - The next reboot of this VM gives you a normal login prompt.\n  - You can re-arm with: cp /usr/local/sbin/samba-init.getty-dropin\n    /etc/systemd/system/getty@tty1.service.d/samba-init.conf\n    && rm /var/lib/samba-init.done && reboot." 16 "$WT_WIDTH" || return

    sudo touch "$MARKER"
    if [[ -f "$GETTY_DROPIN" ]]; then
        sudo rm -f "$GETTY_DROPIN"
        sudo systemctl daemon-reload
    fi
    whiptail --msgbox "Setup marked complete.\n\nReboot or run 'sudo systemctl restart getty@tty1.service' to drop the autologin and pick up the normal login prompt." 13 "$WT_WIDTH"
    exit 0
}

# ----------------------------------------------------------------------------
# Outer text-mode menu — what the operator sees first on the console.
# Picks dispatch to either a direct text action ([U]/[P]/[S]/[H]/[R]/[D]/[Q])
# or the whiptail TUI loop ([I]).
# ----------------------------------------------------------------------------

print_banner() {
    load_detect_env
    clear
    local hn tz
    hn=$(hostnamectl hostname 2>/dev/null || hostname)
    tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo Etc/UTC)
    cat <<BAN
==============================================================
  Samba AD DC Appliance — initial setup
==============================================================
BAN
    printf '  Host: %-15s  IP: %-18s  TZ: %s\n' \
        "$hn" "${DET_IP:-<none>}" "$tz"
    printf '  GW:   %-15s  DNS: %s\n' \
        "${DET_GATEWAY:-<none>}" "${DET_DHCP_DNS:-1.1.1.1 (fallback)}"
    if [[ -n "$DET_PTR_FQDN" || -n "$DET_EFFECTIVE_DOMAIN" ]]; then
        local dom_src=""
        if [[ -n "$DET_DHCP_DOMAIN" ]]; then
            dom_src="via DHCP"
        elif [[ -n "$DET_PTR_DOMAIN" ]]; then
            dom_src="via PTR"
        fi
        printf '  PTR:  %-25s  Domain: %s%s\n' \
            "${DET_PTR_FQDN:-<none>}" \
            "${DET_EFFECTIVE_DOMAIN:-<none>}" \
            "${dom_src:+ ($dom_src)}"
    fi
    if [[ -n "$DET_AD_DC" ]]; then
        printf '  AD:   join %s — DC at %s\n' "${DET_AD_REALM:-$DET_EFFECTIVE_DOMAIN}" "$DET_AD_DC"
    elif [[ -n "$DET_EFFECTIVE_DOMAIN" ]]; then
        printf '  AD:   no DC at %s — provision-new can use this realm\n' \
            "$DET_EFFECTIVE_DOMAIN"
    fi
    [[ -f "$DEFAULT_PWD_MARKER" ]] && \
        echo "  Default password ACTIVE — change before remote use"
    [[ -f /var/run/reboot-required ]] && \
        echo "  REBOOT REQUIRED — pick [R] to apply pending kernel/library upgrades"
    echo "=============================================================="
}

action_update() {
    clear
    echo "Refreshing apt indexes and applying upgrades (full-upgrade)..."
    echo "Note: full-upgrade can install new dependencies (kernels, etc.)."
    echo "      Plain 'apt-get upgrade' would silently keep them back —"
    echo "      Debian metapackages like linux-image-cloud-amd64 only"
    echo "      pick up new kernel ABIs through full-upgrade."
    echo
    if command -v appcore_apt_run_full_upgrade >/dev/null 2>&1; then
        sudo DEBIAN_FRONTEND=noninteractive bash -c \
            'source /usr/local/lib/appliance-core/apt-helpers.sh; appcore_apt_run_full_upgrade'
    else
        # Fallback for older images.
        sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
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
        echo "  Pick [R] from the menu (or run 'sudo reboot') to apply."
    else
        echo "  Done. No reboot required."
    fi
    echo "=============================================================="
    echo "  Press Enter to return to the menu."
    read -r _
}

action_set_password() {
    clear
    echo "Set the ${SELF_USER} password and enable SSH password auth."
    echo "Until now, SSH only accepts the build operator's pre-baked key."
    echo
    local p1 p2
    while true; do
        read -srp "  New password (min 12 chars): " p1; echo
        if [[ ${#p1} -lt 12 ]]; then echo "  Too short."; continue; fi
        read -srp "  Confirm:                      " p2; echo
        if [[ "$p1" != "$p2" ]]; then echo "  Mismatch."; continue; fi
        break
    done
    echo "${SELF_USER}:${p1}" | sudo chpasswd
    echo "PasswordAuthentication yes" | \
        sudo tee /etc/ssh/sshd_config.d/99-samba-init-password.conf >/dev/null
    sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd 2>/dev/null || true
    sudo rm -f "$DEFAULT_PWD_MARKER"
    echo
    echo "  Password set. SSH password auth enabled."
    [[ -n "$DET_IP" ]] && echo "  Remote login: ssh ${SELF_USER}@${DET_IP}"
    echo "  Press Enter."
    read -r _
}

action_run_tui() {
    while true; do
        local choice
        choice=$(whiptail --title "samba-init — interactive setup (TUI)" --nocancel \
            --menu "Detailed steps. [B] returns to the outer text menu." \
            "$WT_HEIGHT" "$WT_WIDTH" "$WT_MENU" \
            "1" "Show network & setup status" \
            "2" "Configure network (DHCP / static)" \
            "3" "Change ${SELF_USER} password" \
            "4" "Add an SSH authorized_keys entry" \
            "5" "Set hostname (suggests PTR if detected)" \
            "6" "Set timezone (with optional network hint)" \
            "7" "Show samba-firstboot log" \
            "S" "Drop to a root shell" \
            "D" "Mark setup complete and proceed to login" \
            "B" "Back to outer text menu" \
            3>&1 1>&2 2>&3)
        case "$choice" in
            1) show_status ;;
            2) config_network ;;
            3) change_password ;;
            4) add_ssh_key ;;
            5) set_hostname ;;
            6) set_timezone ;;
            7) show_firstboot_log ;;
            S|s) clear; sudo bash; ;;
            D|d) mark_done_tui ;;
            B|b|"") return ;;
        esac
    done
}

action_shell() {
    clear
    echo "Dropping to a root shell. 'exit' returns to this menu."
    sudo bash || true
}

action_halt() {
    clear; echo "Halting in 3s — Ctrl-C to abort."; sleep 3
    sudo systemctl poweroff
    exec sleep 60
}

action_reboot() {
    clear; echo "Rebooting in 3s — Ctrl-C to abort."; sleep 3
    sudo systemctl reboot
    exec sleep 60
}

action_mark_done_outer() {
    if [[ -f "$DEFAULT_PWD_MARKER" ]]; then
        echo
        echo "  Cannot mark complete: ${SELF_USER} still has the factory default"
        echo "  password. Pick [P] to change it first."
        echo "  Press Enter."
        read -r _
        return
    fi
    sudo touch "$MARKER"
    if [[ -f "$GETTY_DROPIN" ]]; then
        sudo rm -f "$GETTY_DROPIN"
        sudo systemctl daemon-reload
    fi
    echo
    echo "  Setup marked complete. Dropping to a normal login shell."
    sleep 1
    exec /bin/bash --login
}

action_quit() {
    echo "  Skipping menu for this boot only. exec'ing /bin/bash --login."
    sleep 1
    exec /bin/bash --login
}

# Outer menu loop. Layout target: ≤24 lines on a fresh boot console so
# nothing scrolls off the top of an 80x24 VT.
while true; do
    print_banner
    read -r upg sec < <(count_upgrades)
    echo
    if [[ "$upg" -gt 0 ]] 2>/dev/null; then
        printf '  [U] Update OS (%d pending, %d security)\n' "$upg" "$sec"
    fi
    echo  "  [P] Set ${SELF_USER} password (also enables SSH password auth)"
    echo  "  [I] Interactive setup wizard (TUI: network, hostname, timezone, key)"
    echo  "  [S] Root shell    [D] Mark setup complete    [Q] Skip menu"
    echo  "  [H] Halt          [R] Reboot"
    echo
    read -rp "  > " choice
    case "${choice^^}" in
        U) [[ "$upg" -gt 0 ]] 2>/dev/null && action_update ;;
        P) action_set_password ;;
        I) action_run_tui ;;
        S) action_shell ;;
        D) action_mark_done_outer ;;
        H) action_halt ;;
        R) action_reboot ;;
        Q) action_quit ;;
        *) ;;
    esac
done
INITEOF
chmod +x /usr/local/sbin/samba-init

# TTY1 autologin override. agetty will spawn a debadmin shell without
# password; debadmin's .profile launches the wizard. After the wizard
# acknowledges setup, this drop-in is removed and TTY1 falls back to the
# stock getty. The same content is also kept under /usr/local/sbin/ so
# RELEASE.md's "re-arm the wizard" recipe is a simple cp.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /usr/local/sbin/samba-init.getty-dropin <<'GETTYEOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin debadmin --noclear --keep-baud %I 115200,38400,9600 $TERM
Type=idle
GETTYEOF
cp /usr/local/sbin/samba-init.getty-dropin \
   /etc/systemd/system/getty@tty1.service.d/samba-init.conf

# debadmin's profile launches the wizard on TTY1. SSH sessions don't run
# the wizard because $(tty) returns /dev/pts/N for SSH; only TTY1 hits it.
mkdir -p /home/debadmin
cat > /home/debadmin/.profile <<'PROFILEEOF'
# Auto-launch samba-init on TTY1 only, while initial setup is pending.
# SSH and other TTYs fall through to a normal shell.
if [[ -t 0 ]] && [[ "$(tty)" == "/dev/tty1" ]] && [[ ! -f /var/lib/samba-init.done ]]; then
    exec /usr/local/sbin/samba-init
fi
PROFILEEOF
chown debadmin:debadmin /home/debadmin/.profile 2>/dev/null || true

#===============================================================================
# 24. NETWORK-AWARE LOGIN BANNER (MOTD)
#===============================================================================
# Standard Debian pam_motd runs every executable under /etc/update-motd.d/
# at login and concatenates their stdout. This snippet shows the deployed
# operator the basics they're going to want at first contact: where the
# host is on the network, what state the appliance is in, and what to
# run next.
log "Installing samba-net-status MOTD generator..."
cat > /etc/update-motd.d/15-samba-net-status <<'MOTDEOF'
#!/bin/sh
DET=/var/lib/samba-init-detected.env
[ -r "$DET" ] && . "$DET" 2>/dev/null
printf '\n  Samba Active Directory Domain Controller\n'
printf '  ----------------------------------------\n'
printf '  Hostname:    %s\n' "$(hostnamectl hostname 2>/dev/null || hostname)"
printf '  Network:\n'
ip -br addr show 2>/dev/null | awk 'NF>0 && $1!="lo" {printf "    %s\n", $0}'
gw=$(ip route show default 2>/dev/null | awk '/default/ {print $3" via "$5; exit}')
[ -n "$gw" ] && printf '  Default route: %s\n' "$gw" || printf '  Default route: (none)\n'
# DNS via resolvectl when systemd-resolved is up; else fall back to resolv.conf.
if dns=$(resolvectl dns 2>/dev/null | awk '/^Link [0-9]/ {for(i=4;i<=NF;i++) printf "%s ", $i}'); [ -n "$dns" ]; then
    printf '  DNS:         %s\n' "$dns"
else
    dns=$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)
    [ -n "$dns" ] && printf '  DNS:         %s\n' "$dns"
fi
[ -n "$APPCORE_DET_PTR_FQDN" ] && printf '  PTR for IP:  %s\n' "$APPCORE_DET_PTR_FQDN"
if [ -n "$APPCORE_DET_EFFECTIVE_DOMAIN" ]; then
    if [ "$APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE" = "dhcp" ]; then
        printf '  Domain:      %s (via DHCP)\n' "$APPCORE_DET_EFFECTIVE_DOMAIN"
    elif [ "$APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE" = "ptr" ]; then
        printf '  Domain:      %s (via PTR)\n' "$APPCORE_DET_EFFECTIVE_DOMAIN"
    fi
fi
if [ -n "$SAMBA_DET_AD_DC" ]; then
    printf '  AD DC found: %s (existing forest at %s)\n' "$SAMBA_DET_AD_DC" "${SAMBA_DET_AD_REALM:-$APPCORE_DET_EFFECTIVE_DOMAIN}"
fi
printf '  Setup wizard: %s\n' "$([ -f /var/lib/samba-init.done ] && echo done || echo 'PENDING — open the console for the wizard')"
# `systemctl is-active` already prints active/inactive/failed/unknown to
# stdout for all states; the `|| echo` fallback only fires when systemctl
# itself errored, which would also leave stderr noise. Trim to just the
# stdout content.
ad_state=$(systemctl is-active samba-ad-dc 2>/dev/null || true)
printf '  AD DC svc:    %s\n' "${ad_state:-unavailable}"
# One-line next-step hint based on detection + provisioning state.
if [ ! -f /etc/samba/smb.conf ]; then
    if [ -n "$SAMBA_DET_AD_DC" ]; then
        printf '  Next step:   sudo samba-sconfig (Domain Operations -> Join existing forest)\n'
    elif [ -n "$APPCORE_DET_EFFECTIVE_DOMAIN" ]; then
        printf '  Next step:   sudo samba-sconfig (Domain Operations -> Provision new forest)\n'
    else
        printf '  Next step:   sudo samba-sconfig (configure realm / join / provision)\n'
    fi
fi
printf '\n'
MOTDEOF
chmod +x /etc/update-motd.d/15-samba-net-status

#===============================================================================
# 25. FINAL CLEANUP
#===============================================================================
log "Applying final package updates..."
apt-get update -y
apt-get full-upgrade -y

# The lab seed necessarily gives the build VM a routable FQDN. That identity
# must not survive in the deploy master: it would otherwise become a false
# domain-detection fallback on networks without DHCP search-domain or PTR.
log "Generalizing build-time host identity..."
build_fqdn=$(hostname -f 2>/dev/null || true)
master_ip=$(ip -o -4 addr show scope global 2>/dev/null \
    | awk 'NR==1 {sub(/\/.*$/,"",$4); print $4}')
# shellcheck disable=SC1091
source "$LIB_TARGET/identity.sh"
# shellcheck disable=SC1091
source "$LIB_TARGET/tui.sh"
# shellcheck disable=SC1091
source "$LIB_TARGET/detect-net.sh"
# shellcheck disable=SC1091
source "$LIB_TARGET/hostname.sh"
appcore_hostname_apply_safe "samba-dc1" "" "$master_ip" || {
    err "failed to generalize build-time hostname"
    exit 1
}
if ! command -v cloud-init >/dev/null 2>&1; then
    err "cloud-init is unavailable; cannot remove the build seed safely"
    exit 1
fi
cloud-init clean --logs --seed
apt-get purge -y "${DEFERRED_REMOVE_PKGS[@]}"
if [[ "$build_fqdn" == *.* ]]; then
    if grep -Fq "$build_fqdn" /etc/hostname /etc/hosts; then
        err "build-time FQDN remains active after generalization: $build_fqdn"
        exit 1
    fi
    if grep -R -Fq "$build_fqdn" /var/lib/cloud 2>/dev/null; then
        err "build-time FQDN remains in cloud-init state: $build_fqdn"
        exit 1
    fi
fi

log "Final cleanup..."
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/*
journalctl --vacuum-size=10M 2>/dev/null || true

unset DEBIAN_FRONTEND

#===============================================================================
# SUMMARY
#===============================================================================
echo ""
log "=========================================="
log " Image preparation complete."
log "=========================================="
echo ""
echo "  Samba:         $(samba --version 2>/dev/null || echo 'check manually')"
echo "  PowerShell:    $(pwsh --version 2>/dev/null || echo 'not installed')"
echo "  Chrony:        $(chronyc --version 2>/dev/null || echo 'check manually')"
echo "  Guest agents:  $(find /var/cache/samba-appliance/vmtools -maxdepth 1 -mindepth 1 -not -name manifest -printf '%f ' 2>/dev/null)"
echo ""
echo "  Removed:       ${REMOVE_PKGS[*]} ${DEFERRED_REMOVE_PKGS[*]}"
echo ""
echo "  Next steps:"
echo "    1. Shut down this VM. The shutdown-state disk is the host-agnostic"
echo "       deploy master — copy/export it to any hypervisor you want."
echo "    2. On a deployed VM's first boot, samba-firstboot.service will detect"
echo "       the actual hypervisor, install the matching guest agent offline,"
echo "       and print recommended VM hardware to the console + /etc/motd.d/."
echo "    3. Run 'sudo samba-sconfig' to provision or join a domain."
echo ""

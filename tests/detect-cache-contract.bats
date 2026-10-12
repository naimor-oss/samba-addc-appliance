#!/usr/bin/env bats
# The first-boot loader reads the detection cache with appcore_kv_load, which
# refuses unknown keys. This pins the contract between appliance-core's cache
# writer and this appliance's key list: a field the library adds must not make
# the whole file unreadable (which would silently drop the AD-DC hints).

setup() {
    CORE="${BATS_TEST_DIRNAME}/../../appliance-core/lib"
    PREPARE="${BATS_TEST_DIRNAME}/../prepare-image.sh"
    DETECT_FILE="${BATS_TEST_TMPDIR}/detected.env"
    # The generated first-boot script, cut down to the cache loader.
    awk '
        /^cat > \/usr\/local\/sbin\/samba-init <<'\''INITEOF'\''/ {copy=1; next}
        /^INITEOF$/ {copy=0}
        copy
    ' "$PREPARE" | awk '
        /^load_detect_env\(\) \{/ {infn=1}
        infn {print}
        infn && /^}/ {exit}
    ' > "${BATS_TEST_TMPDIR}/loader.sh"
    [ -s "${BATS_TEST_TMPDIR}/loader.sh" ]
}

@test "the loader reads the cache the current appliance-core writes, AD-DC hints included" {
    # shellcheck disable=SC1091
    source "$CORE/kvstate.sh"
    # shellcheck disable=SC1091
    source "$CORE/detect-net.sh"
    APPCORE_DET_IFACE=eth0 APPCORE_DET_IP=10.10.10.20 APPCORE_DET_GATEWAY=10.10.10.1
    APPCORE_DET_DHCP_DNS=10.10.10.10 APPCORE_DET_DHCP_DOMAIN=lab.test
    APPCORE_DET_PTR_FQDN="" APPCORE_DET_PTR_NAME="" APPCORE_DET_PTR_DOMAIN=""
    appcore_detect_net_write_cache "$DETECT_FILE"
    cat >> "$DETECT_FILE" <<'EOT'
SAMBA_DET_AD_DC="ws2025-dc1.lab.test"
SAMBA_DET_AD_REALM="lab.test"
EOT

    # shellcheck disable=SC1090
    source "${BATS_TEST_TMPDIR}/loader.sh"
    appcore_detect_net_init() { :; }
    load_detect_env

    [ "$SAMBA_DET_AD_DC" = "ws2025-dc1.lab.test" ]
    [ "$SAMBA_DET_AD_REALM" = "lab.test" ]
    [ "$APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE" = "dhcp" ]
}

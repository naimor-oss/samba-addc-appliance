#!/usr/bin/env bats

setup() {
    export SAMBA_SCONFIG_SOURCE_ONLY=1
    export SAMBA_DETECT_FILE="${BATS_TMPDIR}/samba-detected.env"
    source "${BATS_TEST_DIRNAME}/../samba-sconfig.sh"
}

teardown() {
    unset SAMBA_SCONFIG_SOURCE_ONLY SAMBA_DETECT_FILE \
          SAMBA_DEFAULT_REALM SAMBA_DEFAULT_FORWARDER SAMBA_DEFAULT_DC
}

@test "domain defaults come from the canonical network and AD context" {
    appcore_detect_net_init() {
        APPCORE_DET_IP="192.168.50.20"
        APPCORE_DET_GATEWAY="192.168.50.1"
        APPCORE_DET_DHCP_DNS="192.168.50.10 192.168.50.11"
        APPCORE_DET_DHCP_DOMAIN="factory.example"
        APPCORE_DET_PTR_FQDN="dc2.factory.example"
        APPCORE_DET_PTR_NAME="dc2"
        APPCORE_DET_PTR_DOMAIN="factory.example"
        APPCORE_DET_EFFECTIVE_DOMAIN="factory.example"
        APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE="dhcp"
    }
    timeout() {
        shift
        "$@"
    }
    dig() {
        echo "0 100 389 dc1.factory.example."
    }

    set_domain_defaults

    [ "$SAMBA_DEFAULT_REALM" = "FACTORY.EXAMPLE" ]
    [ "$SAMBA_DEFAULT_FORWARDER" = "192.168.50.10" ]
    [ "$SAMBA_DEFAULT_DC" = "dc1.factory.example" ]
}

@test "cached AD DC is ignored when its realm differs from the live domain" {
    cat > "$SAMBA_DETECT_FILE" <<'EOF'
SAMBA_DET_AD_DC="dc1.lab.test"
SAMBA_DET_AD_REALM="lab.test"
EOF
    appcore_detect_net_init() {
        APPCORE_DET_IP="192.168.50.20"
        APPCORE_DET_GATEWAY="192.168.50.1"
        APPCORE_DET_DHCP_DNS="192.168.50.1"
        APPCORE_DET_DHCP_DOMAIN="factory.example"
        APPCORE_DET_PTR_FQDN=""
        APPCORE_DET_PTR_NAME=""
        APPCORE_DET_PTR_DOMAIN=""
        APPCORE_DET_EFFECTIVE_DOMAIN="factory.example"
        APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE="dhcp"
    }
    timeout() {
        return 1
    }

    set_domain_defaults

    [ "$SAMBA_DEFAULT_REALM" = "FACTORY.EXAMPLE" ]
    [ -z "$SAMBA_DEFAULT_DC" ]
}

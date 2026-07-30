#!/usr/bin/env bats

setup() {
    REPO_DIR="${BATS_TEST_DIRNAME}/.."
    PREPARE="${REPO_DIR}/prepare-image.sh"
    BUILD="${REPO_DIR}/lab/build-fresh-base.sh"
    EXPORT="${REPO_DIR}/lab/export-deploy-master.sh"
}

@test "release preparation neutralizes the lab hostname and cloud-init seed" {
    grep -q 'appcore_hostname_apply_safe "samba-dc1" ""' "$PREPARE"
    grep -q 'cloud-init clean --logs --seed' "$PREPARE"
    grep -q 'build-time FQDN remains active after generalization' "$PREPARE"
}

@test "release build requires clean, attributable source trees" {
    grep -q 'require_clean_source "$REPO_DIR"' "$BUILD"
    grep -q 'require_clean_source "$APPCORE_REPO"' "$BUILD"
    grep -q "SAMBA_BUILD_COMMIT=" "$BUILD"
    grep -q "SOURCE_TREE_STATE=clean" "$BUILD"
    grep -q "consumer-commit=%s" "$PREPARE"
    grep -q "consumer-tree-state=%s" "$PREPARE"
}

@test "generated firstboot uses appliance-core as its network detector" {
    grep -q 'appcore_detect_net_write_cache "$DETECT_FILE"' "$PREPARE"
    ! grep -q '^det_ip=$(ip -o -4 addr show scope global' "$PREPARE"
    grep -q 'SAMBA_DET_AD_DC=' "$PREPARE"
}

@test "domain-operation prompts consume the detected defaults" {
    sconfig="${REPO_DIR}/samba-sconfig.sh"
    grep -q '12 64 "$SAMBA_DEFAULT_REALM"' "$sconfig"
    grep -q '10 64 "${SAMBA_DEFAULT_FORWARDER:-1.1.1.1}"' "$sconfig"
    grep -q '10 64 "${SAMBA_DEFAULT_DC:-}"' "$sconfig"
}

@test "canonical OVA is generic, portable, and refuses version collisions" {
    grep -q 'OVA_OUT="$DIST_VER_DIR/${ARTIFACT_BASE}.ova"' "$EXPORT"
    grep -q 'ide0:0.deviceType = "disk"' "$EXPORT"
    grep -q 'ethernet0.virtualDev = "e1000"' "$EXPORT"
    ! grep -q 'scsi0.virtualDev' "$EXPORT"
    ! grep -q 'vmxnet3' "$EXPORT"
    grep -q 'artifact directory already exists' "$EXPORT"
    grep -q -- '--ova-only' "$EXPORT"
    grep -q 'PACKAGE_TMP=$(mktemp -d' "$EXPORT"
    grep -q 'trap cleanup_package_tmp EXIT' "$EXPORT"
}

@test "generated firstboot, initial-setup, and MOTD scripts parse" {
    firstboot="${BATS_TMPDIR}/samba-firstboot"
    initial="${BATS_TMPDIR}/samba-init"
    motd="${BATS_TMPDIR}/15-samba-net-status"
    awk '
        /^cat > \/usr\/local\/sbin\/samba-firstboot <<'\''FBEOF'\''/ {copy=1; next}
        /^FBEOF$/ {copy=0}
        copy
    ' "$PREPARE" > "$firstboot"
    awk '
        /^cat > \/usr\/local\/sbin\/samba-init <<'\''INITEOF'\''/ {copy=1; next}
        /^INITEOF$/ {copy=0}
        copy
    ' "$PREPARE" > "$initial"
    awk '
        /^cat > \/etc\/update-motd.d\/15-samba-net-status <<'\''MOTDEOF'\''/ {copy=1; next}
        /^MOTDEOF$/ {copy=0}
        copy
    ' "$PREPARE" > "$motd"

    [ -s "$firstboot" ]
    [ -s "$initial" ]
    [ -s "$motd" ]
    bash -n "$firstboot"
    bash -n "$initial"
    sh -n "$motd"
}

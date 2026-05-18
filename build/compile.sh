# shellcheck shell=bash
# shellcheck disable=SC2164,SC2153

################################################################################
# Build compilation
################################################################################

build_kernel() {
    step "Build kernel"

    cd "$KERNEL"

    prune_bad_artifacts "$KERNEL_OUT"

    # BBG: update defconfig BEFORE merge so it propagates
    if is_true "$BBG"; then
        local defconfig_file="$KERNEL/arch/arm64/configs/$KERNEL_DEFCONFIG"
        if grep -q 'CONFIG_LSM=' "$defconfig_file"; then
            sed -i 's/CONFIG_LSM=\(.*\)/CONFIG_LSM=\1,baseband_guard/' "$defconfig_file"
        else
            echo 'CONFIG_LSM="selinux,baseband_guard"' >> "$defconfig_file"
        fi
    fi

    if [[ "$BUILD_TARGET" == xaga ]]; then
        info "Merging defconfig"
        local configs="arch/arm64/configs"
        KCONFIG_CONFIG="$configs/gki_defconfig" scripts/kconfig/merge_config.sh -m -r "$configs/gki_defconfig" "$configs/vendor/xiaomi_mt6895.config" "$configs/vendor/xaga.config"
    fi

    info "Generate defconfig: $KERNEL_DEFCONFIG"
    make "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG"

    # BBG: fix CONFIG_LSM in generated .config (make defconfig overwrites it)
    if is_true "$BBG"; then
        sed -i 's/CONFIG_LSM=\(.*\)/CONFIG_LSM=\1,baseband_guard/' "$KERNEL_OUT/.config"
        make "${MAKE_ARGS[@]}" olddefconfig
        info "CONFIG_LSM patched in .config for BBG"
    fi

    info "Building Image and modules..."
    make "${MAKE_ARGS[@]}" Image modules
    success "Kernel built successfully"

    if [[ "$BUILD_TARGET" == xaga ]]; then
        info "Installing kernel modules..."
        make "${MAKE_ARGS[@]}" INSTALL_MOD_PATH="$KERNEL_OUT"/modules modules_install
    fi

    ccache --show-stats

    # will be use later for metadata/telegram
    # shellcheck disable=SC2034
    KERNEL_VERSION=$(make -s kernelversion | cut -d- -f1)
}

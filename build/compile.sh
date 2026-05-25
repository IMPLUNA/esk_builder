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

        # Ensure all LSM modules are explicitly configured
        cd "$KERNEL_OUT"
        echo 'CONFIG_LSM="lockdown,yama,loadpin,safesetid,integrity,selinux,bpf,baseband_guard"' >> .config
        make "${MAKE_ARGS[@]}" olddefconfig
        cd "$KERNEL"
    fi

    # BBR: verify BBR configs landed in .config, patch if missing
    if is_true "$BBR_V3"; then
        local config_changed=false
        if ! grep -q '^CONFIG_TCP_CONG_BBR=y' "$KERNEL_OUT/.config"; then
            echo 'CONFIG_TCP_CONG_BBR=y' >> "$KERNEL_OUT/.config"
            config_changed=true
        fi
        if ! grep -q '^CONFIG_NET_SCH_FQ=y' "$KERNEL_OUT/.config"; then
            echo 'CONFIG_NET_SCH_FQ=y' >> "$KERNEL_OUT/.config"
            config_changed=true
        fi
        if ! grep -q '^CONFIG_DEFAULT_BBR=y' "$KERNEL_OUT/.config"; then
            sed -i '/^CONFIG_DEFAULT_CUBIC=y/d' "$KERNEL_OUT/.config"
            echo 'CONFIG_DEFAULT_BBR=y' >> "$KERNEL_OUT/.config"
            config_changed=true
        fi
        if $config_changed; then
            make "${MAKE_ARGS[@]}" olddefconfig
            info "BBR configs patched in .config"
        fi
    fi

    # Clang LTO: verify LTO configs landed in .config, patch if missing
    if [[ -n "$CLANG_LTO" ]]; then
        local lto_mode="$CLANG_LTO"
        local config_changed=false
        if ! grep -q '^CONFIG_LTO_CLANG=y' "$KERNEL_OUT/.config"; then
            echo 'CONFIG_LTO_CLANG=y' >> "$KERNEL_OUT/.config"
            config_changed=true
        fi
        sed -i '/^CONFIG_LTO_CLANG_THIN=/d; /^CONFIG_LTO_CLANG_FULL=/d' "$KERNEL_OUT/.config"
        case "$lto_mode" in
            thin)
                echo 'CONFIG_LTO_CLANG_THIN=y' >> "$KERNEL_OUT/.config"
                ;;
            full)
                echo 'CONFIG_LTO_CLANG_FULL=y' >> "$KERNEL_OUT/.config"
                ;;
            *)
                warn "Unknown LTO mode '$lto_mode', using thin"
                echo 'CONFIG_LTO_CLANG_THIN=y' >> "$KERNEL_OUT/.config"
                ;;
        esac
        if $config_changed || grep -q '^CONFIG_LTO_CLANG_THIN=y\|^CONFIG_LTO_CLANG_FULL=y' "$KERNEL_OUT/.config"; then
            make "${MAKE_ARGS[@]}" olddefconfig
            info "LTO ($lto_mode) configs patched in .config"
        fi
    fi

    # KPM: verify KPM config landed in .config, patch if missing
    # Note: GKI 2.0 kernels only require CONFIG_KPM=y and CONFIG_MODULES=y
    if is_true "$KPM"; then
        local config_changed=false

        # KPM requires MODULES to be enabled
        if ! grep -q '^CONFIG_MODULES=y' "$KERNEL_OUT/.config"; then
            echo 'CONFIG_MODULES=y' >> "$KERNEL_OUT/.config"
            config_changed=true
        fi

        # KPM core config
        if ! grep -q '^CONFIG_KPM=y' "$KERNEL_OUT/.config"; then
            echo 'CONFIG_KPM=y' >> "$KERNEL_OUT/.config"
            config_changed=true
        fi

        if $config_changed; then
            make "${MAKE_ARGS[@]}" olddefconfig
            info "KPM configs patched in .config"
        fi
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

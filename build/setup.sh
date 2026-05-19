# shellcheck shell=bash
# shellcheck disable=SC2164,SC2153,SC2034

################################################################################
# Build setup
################################################################################

setup_ccache() {
    export CCACHE_DIR="${CCACHE_DIR:-$WORKSPACE/.ccache}"
    export CCACHE_BASEDIR="$WORKSPACE"
    export CCACHE_COMPILERCHECK="content"
    export CCACHE_NOHASHDIR=true
    export CCACHE_SLOPPINESS="file_stat_matches,include_file_ctime,include_file_mtime,pch_defines,file_macro,time_macro"

    mkdir -p "$CCACHE_DIR"
    ccache --max-size "$CCACHE_SIZE"

    ccache --zero-stats
    ccache --show-config
}

gen_wrapper() {
    local tool="$1"
    local fake_time="2026-03-14 12:00:00"

    cat > "$WORKSPACE/build/$tool" << EOF
#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")/.." && pwd)"

export LD_PRELOAD="\$LIBFAKESTAT \$LIBFAKETIME"
export FAKESTAT="$fake_time"
export FAKETIME="@$fake_time"

exec "\$WORKSPACE/clang/bin/$tool" "\$@"
EOF

    chmod +x "$WORKSPACE/build/$tool"
}

setup_ld_preload() {
    export LIBFAKETIME
    LIBFAKETIME=$(find /usr/lib* /lib* -name libfaketimeMT.so.1 -print -quit 2> /dev/null || true)
    export LIBFAKESTAT

    if [[ ! -f "$LIBFAKESTAT" ]]; then
        local archive="$WORKSPACE/libfakestat.tar.gz"
        local libfakestat_url
        mkdir -p "$LIBFAKESTAT_DIR"

        validate_env github

        libfakestat_url=$(github_release_asset_url "$LIBFAKESTAT_RELEASE_API" "libfakestat.tar.gz")

        curl -fsSLo "$archive" "$libfakestat_url"
        tar -xzf "$archive" -C "$LIBFAKESTAT_DIR"
        rm -f "$archive"
    fi

    if [[ ! -f "$WORKSPACE/build/clang" ]]; then
        gen_wrapper clang
    fi

    if [[ ! -f "$WORKSPACE/build/ld.lld" ]]; then
        gen_wrapper ld.lld
    fi
}

init_build() {
    step "Init build"

    if is_ci; then
        TG_NOTIFY_DEFAULT="true"
        RESET_SOURCES_DEFAULT="true"
    fi

    KSU="$(resolve_bool "${KSU-}" "$KSU_DEFAULT")"
    SUSFS="$(resolve_bool "${SUSFS-}" "$SUSFS_DEFAULT")"
    LXC="$(resolve_bool "${LXC-}" "$LXC_DEFAULT")"
    KPM="$(resolve_bool "${KPM-}" "$KPM_DEFAULT")"
    BBG="$(resolve_bool "${BBG-}" "$BBG_DEFAULT")"
    BBR_V3="$(resolve_bool "${BBR_V3-}" "$BBR_V3_DEFAULT")"
    STOCK_CONFIG="$(resolve_bool "${STOCK_CONFIG-}" "$STOCK_CONFIG_DEFAULT")"

    TG_NOTIFY="$(resolve_bool "${TG_NOTIFY-}" "$TG_NOTIFY_DEFAULT")"
    RESET_SOURCES="$(resolve_bool "${RESET_SOURCES-}" "$RESET_SOURCES_DEFAULT")"

    # before the build starts
    validate_deps base

    BUILD_TAG="kernel_$(hexdump -v -e '/1 "%02x"' -n4 /dev/urandom)"
    info "Build tag generated: $BUILD_TAG"

    # Compiler setup
    setup_ccache
    setup_ld_preload

    # Make arguments
    MAKE_ARGS=(
        -j"$JOBS" O="$KERNEL_OUT" ARCH="arm64"
        CC="ccache clang" CROSS_COMPILE="aarch64-linux-gnu-"
        LLVM="1" LD="ld.lld"
    )

    info "Building in $(is_ci && echo CI || echo local)"

    # Set timezone
    export TZ="$TIMEZONE"
}

prepare_dirs() {
    step "Prepare directories"

    for dir in "$OUT_DIR" "$BOOT_IMAGE" "$AK3"; do
        reset_dir "$dir"
    done

    if is_true "$RESET_SOURCES"; then
        for dir in "$KERNEL" "$BUILD_TOOLS" "$MKBOOTIMG" "$SUSFS_DIR"; do
            reset_dir "$dir"
        done
    fi
}

fetch_sources() {
    step "Fetch sources"

    info "Cloning kernel source..."
    git_clone "$KERNEL_REPO" "$KERNEL"

    info "Cloning AnyKernel3..."
    git_clone "$AK3_REPO" "$AK3"

    info "Cloning build tools..."
    git_clone "$BUILD_TOOLS_REPO" "$BUILD_TOOLS"
    git_clone "$MKBOOTIMG_REPO" "$MKBOOTIMG"
}

setup_toolchain() {
    step "Setup toolchain"

    _use_toolchain() {
        export PATH="$WORKSPACE/build:$CLANG_BIN:$PATH"
        COMPILER_STRING="$("$CLANG_BIN/clang" --version | head -n 1 | sed 's/(https..*//')"
        export KBUILD_BUILD_USER KBUILD_BUILD_HOST
    }

    if [[ -x "$CLANG_BIN/clang" ]]; then
        info "Using existing AOSP Clang toolchain"
        _use_toolchain
        return 0
    fi

    validate_env github

    info "Fetching AOSP Clang toolchain"
    local clang_url
    clang_url=$(
        github_release_asset_url \
            "https://api.github.com/repos/bachnxuan/aosp_clang_mirror/releases/latest" \
            "clang-r*.tar.gz"
    )

    mkdir -p "$CLANG"

    local aria_opts=(
        -q -c -x16 -s16 -k8M -m 5 --retry-wait=5
        --file-allocation=falloc
        -d "$WORKSPACE" -o "clang-archive" "$clang_url"
    )

    if aria2c "${aria_opts[@]}"; then
        success "Clang download successful!"
    else
        error "Clang download failed."
    fi

    tar -xzf "$WORKSPACE/clang-archive" -C "$CLANG"
    rm -f "$WORKSPACE/clang-archive"

    _use_toolchain
}

apply_susfs() {
    info "Apply SuSFS kernel-side patches"

    local susfs_dir="$SUSFS_DIR"
    local susfs_patches="$susfs_dir/kernel_patches"

    git_clone "$SUSFS_REPO" "$susfs_dir"
    cp -R "$susfs_patches"/fs/* ./fs
    cp -R "$susfs_patches"/include/* ./include

    patch -s -p1 --fuzz=3 --no-backup-if-mismatch < "$susfs_patches"/50_add_susfs_in_gki-android*-*.patch

    SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')

    config --enable CONFIG_KSU_SUSFS

    success "SuSFS applied!"
}

apply_bbg() {
    info "Apply Baseband Guard (BBG) patches"

    local bbg_dir="$BBG_DIR"

    # Clone BBG repository
    git_clone "$BBG_REPO" "$bbg_dir"

    # Run BBG's own setup.sh from the kernel source directory.
    # It handles symlink, Makefile, Kconfig, and SELinux patches correctly.
    pushd "$KERNEL" > /dev/null
    bash "$bbg_dir/setup.sh"
    popd > /dev/null

    # Enable BBG in kernel defconfig
    config --enable CONFIG_BBG

    # NOTE: CONFIG_LSM is updated in build_kernel() after defconfig merge,
    # because xaga's merge_config.sh would overwrite it here.

    success "Baseband Guard applied!"
}

apply_bbr_v3() {
    info "Apply BBR v3 network optimization"

    local defconfig_file="$KERNEL/arch/arm64/configs/$KERNEL_DEFCONFIG"
    if [[ -f "$defconfig_file" ]]; then
        # Remove stale entries if present
        sed -i '/CONFIG_DEFAULT_TCP_CONG/d' "$defconfig_file"
        sed -i '/CONFIG_TCP_CONG_BBR3/d' "$defconfig_file"
        sed -i '/CONFIG_TCP_CONG_BBR/d' "$defconfig_file"
        sed -i '/CONFIG_NET_SCH_FQ/d' "$defconfig_file"

        cat >> "$defconfig_file" << EOF
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_BBR3=y
CONFIG_NET_SCH_FQ=y
CONFIG_DEFAULT_TCP_CONG="bbr"
EOF
        info "BBR v3 configuration added to defconfig"
    fi

    success "BBR v3 network optimization applied!"
}

prepare_build() {
    step "Prepare build"

    # Validate feature combinations before patching/build prep.
    validate_env config

    if is_true "$SUSFS" || is_true "$LXC" || is_true "$STOCK_CONFIG"; then
        # Only needed when patches may be applied.
        validate_deps patching
    fi

    cd "$KERNEL"

    # Defconfig existence check
    local defconfig_file="$KERNEL/arch/arm64/configs/$KERNEL_DEFCONFIG"
    if [[ ! -f $defconfig_file ]]; then
        error "Defconfig not found: $KERNEL_DEFCONFIG"
    fi

    if is_true "$KSU"; then
        info "Setup ReSukiSU"
        install_ksu "ESK-Project/ReSukiSU" "main"
        config --enable CONFIG_KSU
        success "ReSukiSU added"
    fi

    # SuSFS
    if is_true "$SUSFS"; then
        apply_susfs
    else
        config --disable CONFIG_KSU_SUSFS
    fi

    # LXC
    if is_true "$LXC"; then
        info "Apply LXC patch"
        patch -s -p1 --fuzz=3 --no-backup-if-mismatch < "$KERNEL_PATCHES/lxc_support.patch"
    fi

    if is_true "$STOCK_CONFIG"; then
        info "Apply stock config patch"
        patch -s -p1 --fuzz=3 --no-backup-if-mismatch < "$KERNEL_PATCHES/stock_config.patch"
    fi

    # Baseband Guard (BBG)
    if is_true "$BBG"; then
        apply_bbg
    else
        config --disable CONFIG_BBG
    fi

    # KPM (Kernel Patch Module) - requires ReSukiSU
    if is_true "$KPM"; then
        info "Enable KPM (Kernel Patch Module)"
        config --enable CONFIG_KPM
        config --enable CONFIG_KALLSYMS
        config --enable CONFIG_KALLSYMS_ALL
        success "KPM enabled"
    else
        config --disable CONFIG_KPM
    fi

    # BBR v3 Network Optimization
    if is_true "$BBR_V3"; then
        apply_bbr_v3
    fi

    # Config Clang LTO
    clang_lto "$CLANG_LTO"
}

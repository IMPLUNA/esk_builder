# shellcheck shell=bash
# shellcheck disable=SC2034

################################################################################
# Utility functions
################################################################################

source "$WORKSPACE/logging.sh"

require_cmds() {
    local cmd
    local missing_cmds=()

    for cmd in "$@"; do
        if command -v "$cmd" > /dev/null 2>&1; then
            continue
        fi
        missing_cmds+=("$cmd")
    done

    if ((${#missing_cmds[@]} != 0)); then
        fatal "Missing required command(s): ${missing_cmds[*]}"
    fi
}

py_cli() {
    uv run --project "$WORKSPACE/py" tools "$@"
}

# Fetch a release asset URL from a GitHub release API response.
github_release_asset_url() {
    local api_url="$1"
    local pattern="$2"
    py_cli release asset-url "$pattern" --api-url "$api_url"
}

# Escape text for MarkdownV2
escape_md_v2() {
    python3 - "$*" << 'PY'
import re
import sys

s = sys.argv[1]
escaped = re.sub(r'([\\_*[\]()~`>#+\-=|{}.!])', r'\\\1', s)
print(escaped, end="")
PY
}

# Boolean helpers
resolve_bool() {
    local value="${1-}"
    local default_value="${2-}"

    case "${value,,}" in
        "" | auto) echo "${default_value:-false}" ;;
        1 | y | yes | t | true | on) echo "true" ;;
        0 | n | no | f | false | off) echo "false" ;;
        *)
            fatal "Invalid boolean value: $value"
            ;;
    esac
}

is_true() {
    [[ $1 == true ]]
}

parse_bool() {
    if is_true "$1"; then
        echo "on"
    else
        echo "off"
    fi
}

# Check if script is running in Github Action
is_ci() {
    [[ ${GITHUB_ACTIONS:-} == "true" ]]
}

# Recreate directory
reset_dir() {
    local path="$1"
    if [[ -d $path ]]; then
        rm -rf -- "$path"
    fi
    mkdir -p -- "$path"
}

# Remove broken Kbuild outputs to avoid breaking incremental builds
prune_bad_artifacts() {
    local build_dir="$1"

    [[ -d $build_dir ]] || return 0

    find "$build_dir" -type f -size 0 \
        \( -name '*.o' -o -name '*.a' -o -name '*.ko' -o -name '*.symversions' \) \
        -print -delete
}

# Shallow clone repository into a destination
git_clone() {
    local source="$1"
    local dest="$2"
    local host repo branch url
    IFS=':@' read -r host repo branch <<< "$source"

    if [[ -d "$dest/.git" ]]; then
        git -C "$dest" clean -fdx -q
        git -C "$dest" fetch -q --depth=1 --no-tags origin "$branch"
        git -C "$dest" reset -q --hard FETCH_HEAD
        return 0
    fi

    url="https://${host}/${repo}"
    git clone -q --depth=1 --single-branch --no-tags \
        "$url" -b "${branch}" "${dest}"
}

# Setup ReSukiSU
install_ksu() {
    local repo="$1"
    local ref="$2"
    info "Install ReSukiSU: $repo@$ref"
    
    # Run ReSukiSU setup.sh - it will auto-integrate KPM if CONFIG_KPM is in defconfig
    if ! curl -fsSL "https://raw.githubusercontent.com/$repo/$ref/kernel/setup.sh" | bash -s "$ref"; then
        error "ReSukiSU setup.sh failed"
    fi

    info "ReSukiSU/KSU setup completed - KPM integration depends on CONFIG_KPM in defconfig"
}

clang_lto() {
    local lto_mode="$1"
    local defconfig_file="$KERNEL/arch/arm64/configs/$KERNEL_DEFCONFIG"

    # Add LTO config to defconfig during setup phase
    sed -i '/^CONFIG_LTO_CLANG=/d; /^CONFIG_LTO_CLANG_THIN=/d; /^CONFIG_LTO_CLANG_FULL=/d' "$defconfig_file"

    echo 'CONFIG_LTO_CLANG=y' >> "$defconfig_file"

    case "$lto_mode" in
        thin)
            echo 'CONFIG_LTO_CLANG_THIN=y' >> "$defconfig_file"
            ;;
        full)
            echo 'CONFIG_LTO_CLANG_FULL=y' >> "$defconfig_file"
            ;;
        *)
            warn "Unknown LTO mode '$lto_mode', using thin"
            echo 'CONFIG_LTO_CLANG_THIN=y' >> "$defconfig_file"
            ;;
    esac
}

#!/usr/bin/env bash
# KPM 验证脚本 - 检查 KPM 是否正确集成

set -euo pipefail

KERNEL_OUT="${1:-.}"

echo "=== KPM Configuration Check ==="
echo

if [[ ! -f "$KERNEL_OUT/.config" ]]; then
    echo "[ERROR] .config not found at $KERNEL_OUT/.config"
    exit 1
fi

echo "Checking kernel configuration..."
echo

# Check required KPM configs
configs=(
    "CONFIG_MODULES"
    "CONFIG_KPM"
    "CONFIG_KALLSYMS"
    "CONFIG_KALLSYMS_ALL"
    "CONFIG_KPROBES"
)

all_ok=true
for cfg in "${configs[@]}"; do
    if grep -q "^${cfg}=y" "$KERNEL_OUT/.config"; then
        echo "✓ $cfg=y"
    else
        echo "✗ $cfg (not set or disabled)"
        all_ok=false
    fi
done

echo
if $all_ok; then
    echo "✓ All KPM configs are properly set!"
    echo
    echo "Next steps to verify KPM at runtime:"
    echo "1. Check dmesg: dmesg | grep -i kpm"
    echo "2. List loaded modules: lsmod | grep -i kpm"
    echo "3. Check KPM version: cat /proc/kpm"
else
    echo "✗ Some KPM configs are missing!"
    echo
    echo "To debug:"
    echo "1. Check if ReSukiSU setup.sh was executed"
    echo "2. Verify kernel source for KPM module code"
    exit 1
fi

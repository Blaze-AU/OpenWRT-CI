#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
red()    { echo -e "\033[31m$*\033[0m"; }

# ===================== 工具函数 =====================
# 优先用 OpenWrt 自带 scripts/config；不存在时回退到 sed 全形态清理
# 注意：用 -f 判断，避免把目录误判为可执行文件
force_disable_pkg() {
    local pkg="$1"
    local cfg="./.config"

    if [ -f "./scripts/config" ] && [ -x "./scripts/config" ]; then
        ./scripts/config --disable "PACKAGE_${pkg}"
    else
        sed -i "/^CONFIG_PACKAGE_${pkg}=/d"             "$cfg"
        sed -i "/^# CONFIG_PACKAGE_${pkg} is not set/d" "$cfg"
        sed -i "/^CONFIG_${pkg}=/d"                     "$cfg"
        sed -i "/^# CONFIG_${pkg} is not set/d"         "$cfg"
        echo "# CONFIG_PACKAGE_${pkg} is not set" >> "$cfg"
    fi
}

to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
to_upper() { echo "$1" | tr '[:lower:]' '[:upper:]'; }
sq_escape() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

# ===================== 主题 / IP =====================
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
sed -i "s/luci-theme-bootstrap/luci-theme-${WRT_THEME}/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")

# ===================== WiFi =====================
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
if [ -n "$WIFI_SH" ]; then
    for f in $WIFI_SH; do
        sed -i "s/BASE_SSID='.*'/BASE_SSID='${WRT_SSID}'/g" "$f"
        sed -i "s/BASE_WORD='.*'/BASE_WORD='${WRT_WORD}'/g" "$f"
    done
    green "✅ WiFi 参数已写入 set-wireless.sh"
else
    yellow "ℹ️ 未找到 set-wireless.sh，WiFi 参数由 93-wifi-config 设置"
fi

# ===================== 默认 IP / 主机名 =====================
CFG_FILE="./package/base-files/files/bin/config_generate"
if [ -f "$CFG_FILE" ]; then
    sed -i "s/192\.168\.[0-9]*\.[0-9]*/${WRT_IP}/g" "$CFG_FILE"
    sed -i "s/hostname='.*'/hostname='${WRT_NAME}'/g" "$CFG_FILE"
fi

# ===================== 基础配置 =====================
{
    echo "CONFIG_PACKAGE_luci=y"
    echo "CONFIG_LUCI_LANG_zh_Hans=y"
    echo "CONFIG_PACKAGE_luci-theme-${WRT_THEME}=y"
    echo "CONFIG_PACKAGE_luci-app-${WRT_THEME}-config=y"
} >> ./.config

if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
    echo "Applying private configurations from PRIVATE.txt..."
    cat "$GITHUB_WORKSPACE/Config/PRIVATE.txt" >> ./.config
fi

if [ -n "$WRT_PACKAGE" ]; then
    echo -e "$WRT_PACKAGE" >> ./.config
fi

# ===================== 4. 禁用 USB / 存储 =====================
green "=== 4. 禁用 USB / 存储 / 文件系统组件 ==="
USB_STORAGE_PKGS=(
    kmod-usb-core kmod-usb3 kmod-usb-storage kmod-usb-storage-extras
    kmod-usb-dwc3 kmod-usb-dwc3-qcom kmod-usb-common kmod-usb-roles
    kmod-usb-storage-uas kmod-usb-xhci-hcd block-mount automount
    f2fs-tools e2fsprogs ntfs3-mount mkf2fs losetup
    kmod-scsi-core kmod-fs-exfat kmod-fs-ext4 kmod-fs-f2fs kmod-fs-ntfs3 kmod-fs-vfat
    f2fsck
)
for pkg in "${USB_STORAGE_PKGS[@]}"; do
    force_disable_pkg "$pkg"
done
green "✅ USB / 存储禁用完成"

# ===================== 7. pbuf 调度器 =====================
green "=== 7. pbuf 调频策略 ==="
PBUF_CONF="./package/kernel/mac80211/files/pbuf.uci"
if [ -f "$PBUF_CONF" ]; then
    if grep -q "scaling_governor 'performance'" "$PBUF_CONF"; then
        sed -i "s@scaling_governor 'performance'@scaling_governor 'schedutil'@g" "$PBUF_CONF"
        green "✅ pbuf governor 已改为 schedutil"
    else
        yellow "ℹ️ pbuf.uci 中未找到 performance governor，跳过"
    fi
else
    yellow "ℹ️ 未找到 pbuf.uci，跳过"
fi

# ===================== 93-wifi-config =====================
green "=== 93-wifi-config：WiFi 基础配置 ==="
SAFE_SSID=$(sq_escape "$WRT_SSID")
SAFE_WORD=$(sq_escape "$WRT_WORD")

UCI_DEFAULTS_DIR="./package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DEFAULTS_DIR"

cat > "$UCI_DEFAULTS_DIR/93-wifi-config" << EOF
#!/bin/sh
[ -e /etc/config/wireless ] || wifi config

for dev in \$(uci show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-device\$/\1/p'); do
    uci set wireless.\$dev.disabled='0'
    uci set wireless.\$dev.country='CN'
    uci set wireless.\$dev.log_level='1'
done

for iface in \$(uci show wireless | sed -n 's/^wireless\.\([^.=]*\)=wifi-iface\$/\1/p'); do
    uci set wireless.\$iface.ssid='${SAFE_SSID}'
    uci set wireless.\$iface.key='${SAFE_WORD}'
    uci set wireless.\$iface.encryption='psk2+ccmp'
    uci set wireless.\$iface.apsd='0'
done

uci commit wireless
exit 0
EOF
green "✅ 93-wifi-config 已生成（SSID=${WRT_SSID}, 加密=psk2+ccmp）"

# ===================== 无 WIFI 配置标志 =====================
WRT_CONFIG_LC=$(to_lower "$WRT_CONFIG")
if [[ "$WRT_CONFIG_LC" == *wifi* && "$WRT_CONFIG_LC" == *no* ]]; then
    if [ -n "$GITHUB_ENV" ]; then
        echo "WRT_WIFI=wifi-no" >> "$GITHUB_ENV"
    fi
fi

# ===================== 高通平台调整 =====================
DTS_PATH="./target/linux/qualcommax/dts/"
WRT_TARGET_UC=$(to_upper "$WRT_TARGET")
if [[ "$WRT_TARGET_UC" == *QUALCOMMAX* ]]; then
    if [[ "$WRT_CONFIG_LC" == *wifi* && "$WRT_CONFIG_LC" == *no* ]]; then
        find "$DTS_PATH" -type f ! -iname '*nowifi*' -exec \
            sed -i '/nowifi/!s/ipq\(6018\|8074\)\.dtsi/ipq\1-nowifi.dtsi/g' {} +
        echo "qualcommax set up nowifi successfully!"
    fi
fi

# ===================== NSS 配置自检 =====================
green "=== NSS 配置自检 ==="
if [ -f "./.config" ]; then
    for key in \
        CONFIG_PACKAGE_kmod-qca-nss-drv \
        CONFIG_PACKAGE_kmod-qca-nss-drv-wifi \
        CONFIG_PACKAGE_MAC80211_NSS_SUPPORT \
        CONFIG_ATH11K_NSS_SUPPORT \
        CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE
    do
        if grep -q "^${key}=y" ./.config; then
            green "✅ ${key}=y"
        elif grep -q "^# ${key} is not set" ./.config; then
            yellow "⚠️ ${key} 被显式禁用"
        else
            red "❌ ${key} 未出现在 .config 中"
        fi
    done
fi

#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

set -e

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

# ---------- 自动查找 OpenWrt 根目录 ----------
find_openwrt_root() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/scripts/feeds" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

OPENWRT_ROOT=$(find_openwrt_root)
if [ -z "$OPENWRT_ROOT" ]; then
    red "❌ 未找到 OpenWrt 源码根目录（缺少 scripts/feeds）"
    red "请确认当前目录在 OpenWrt 源码树内"
    exit 1
fi

cd "$OPENWRT_ROOT"
green "✅ 切换到 OpenWrt 根目录: $OPENWRT_ROOT"

# ---------- 主流程 ----------
green "========================================="
green "AdGuardHome 自定义包（stevenjoezhang 版 v1.19）"
green "包名改为 luci-app-adguardhome-kong"
green "========================================="

# 1. 清理旧克隆目录
green "🧹 清理旧克隆目录..."
rm -rf package/luci-app-adguardhome-tmp
rm -rf package/luci-app-adguardhome-kong

# 2. 克隆指定 tag（v1.19）
green "📦 克隆 stevenjoezhang/luci-app-adguardhome (tag: v1.19)..."
git clone --depth=1 -b v1.19 https://github.com/stevenjoezhang/luci-app-adguardhome package/luci-app-adguardhome-tmp
mv package/luci-app-adguardhome-tmp package/luci-app-adguardhome-kong

# 3. 修改 Makefile
MAKEFILE="package/luci-app-adguardhome-kong/Makefile"
if [ ! -f "$MAKEFILE" ]; then
    red "❌ Makefile 不存在，请检查克隆是否成功"
    exit 1
fi

# 3a. 修改包名
sed -i 's/^PKG_NAME\s*:=.*/PKG_NAME:=luci-app-adguardhome-kong/' "$MAKEFILE"
green "✅ 已修改 PKG_NAME"

# 3b. 修正版本号，使 APK 打包通过（将 '-' 替换为 '.'，并保证 PKG_RELEASE 为纯数字）
if grep -q '^PKG_VERSION\s*:=' "$MAKEFILE"; then
    OLD_VER=$(grep '^PKG_VERSION\s*:=' "$MAKEFILE" | sed 's/^PKG_VERSION\s*:=\s*//')
    NEW_VER=$(echo "$OLD_VER" | sed 's/-/./g')
    sed -i "s/^PKG_VERSION\s*:=.*/PKG_VERSION:=$NEW_VER/" "$MAKEFILE"
    green "✅ 已修正 PKG_VERSION: $OLD_VER -> $NEW_VER"
else
    yellow "⚠️ 未找到 PKG_VERSION，将添加默认版本"
    echo 'PKG_VERSION:=1.19' >> "$MAKEFILE"
fi

if grep -q '^PKG_RELEASE\s*:=' "$MAKEFILE"; then
    OLD_REL=$(grep '^PKG_RELEASE\s*:=' "$MAKEFILE" | sed 's/^PKG_RELEASE\s*:=\s*//')
    if [[ "$OLD_REL" =~ [^0-9] ]]; then
        sed -i 's/^PKG_RELEASE\s*:=.*/PKG_RELEASE:=1/' "$MAKEFILE"
        green "✅ 已将 PKG_RELEASE 从 '$OLD_REL' 修正为 '1'"
    else
        green "✅ PKG_RELEASE 已合法: $OLD_REL"
    fi
else
    echo 'PKG_RELEASE:=1' >> "$MAKEFILE"
    green "✅ 已添加 PKG_RELEASE:=1"
fi

# 4. 更新 feeds
green "🔄 更新 feeds..."
./scripts/feeds update -a
./scripts/feeds install -a

# 5. 清理官方包目录（避免误选）
green "🧹 删除官方包目录..."
rm -rf feeds/luci/applications/luci-app-adguardhome
rm -rf feeds/packages/net/adguardhome
rm -f feeds/luci.index feeds/packages.index

# 6. 预置核心（arm64）
green "⬇️ 预置 AdGuardHome 核心（arm64）..."
mkdir -p files/usr/bin
if command -v jq >/dev/null 2>&1; then
    AGH_URL=$(curl -sL https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | jq -r '.assets[] | select(.name | test("linux_arm64")) | .browser_download_url' | head -1)
else
    AGH_URL=$(curl -sL https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep -o '"browser_download_url":\s*"[^"]*linux_arm64[^"]*"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
fi

if [ -n "$AGH_URL" ]; then
    wget -qO- "$AGH_URL" | tar -xOz --wildcards '*/AdGuardHome' > files/usr/bin/AdGuardHome 2>/dev/null && {
        chmod +x files/usr/bin/AdGuardHome
        green "✅ 核心下载成功 ($(du -h files/usr/bin/AdGuardHome | cut -f1))"
    } || yellow "⚠️ 核心解压失败"
else
    yellow "⚠️ 未找到 arm64 核心下载链接"
fi

green "========================================="
green "✅ 准备完成"
green "  - 自定义包: luci-app-adguardhome-kong (来自 stevenjoezhang v1.19)"
green "  - 官方包已从 feeds 中移除"
green "  - 请在 .config 中启用："
green "    CONFIG_PACKAGE_luci-app-adguardhome-kong=y"
green "========================================="
exit 0

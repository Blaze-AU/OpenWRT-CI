#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

set -e

# ---------- 颜色输出 ----------
red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

# ---------- 切换到 OpenWrt 根目录 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENWRT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$OPENWRT_ROOT" || { red "❌ 无法进入 OpenWrt 根目录"; exit 1; }
if [ ! -f "scripts/feeds" ]; then
    red "❌ 当前目录不是 OpenWrt 源码根目录（缺少 scripts/feeds）"
    exit 1
fi
green "当前工作目录: $(pwd)"

# ---------- 主流程 ----------
green "========================================="
green "AdGuardHome 自定义包（kongfl888 版）"
green "包名改为 luci-app-adguardhome-kong"
green "========================================="

# 1. 清理官方包
green "🧹 清理官方 AdGuardHome 相关包..."
rm -rf feeds/luci/applications/luci-app-adguardhome
rm -rf feeds/packages/net/adguardhome
rm -f feeds/luci.index feeds/packages.index

# 2. 克隆并重命名
green "📦 克隆 kongfl888/luci-app-adguardhome (master 分支)..."
git clone --depth=1 -b master https://github.com/kongfl888/luci-app-adguardhome package/luci-app-adguardhome-tmp
mv package/luci-app-adguardhome-tmp package/luci-app-adguardhome-kong

# 3. 修改 Makefile 中的包名
MAKEFILE="package/luci-app-adguardhome-kong/Makefile"
if [ -f "$MAKEFILE" ]; then
    sed -i 's/^PKG_NAME\s*:=.*/PKG_NAME:=luci-app-adguardhome-kong/' "$MAKEFILE"
    green "✅ 已修改 Makefile 中的 PKG_NAME"
else
    yellow "⚠️ Makefile 不存在，请手动检查"
fi

# 4. 更新 feeds
green "🔄 更新 feeds..."
./scripts/feeds update -a
./scripts/feeds install -a

# 5. 预置核心（arm64）
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
green "  - 自定义包: luci-app-adguardhome-kong"
green "  - 官方包已被禁用"
green "  - 请在 Settings.sh 或 .config 中启用新包："
green "    CONFIG_PACKAGE_luci-app-adguardhome-kong=y"
green "    CONFIG_PACKAGE_luci-app-adguardhome=n"
green "========================================="
exit 0

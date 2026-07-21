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



# 2. 克隆指定 tag（v1.19）
green "📦 克隆 stevenjoezhang/luci-app-adguardhome (tag: v1.19)..."
git clone --depth=1 -b v1.19 https://github.com/stevenjoezhang/luci-app-adguardhome package/luci-app-adguardhome-tmp



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

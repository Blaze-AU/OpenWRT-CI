#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 拉取 kongfl888 版到 package/ 下，并重命名包名，避免与官方冲突

set -e  # 遇到错误立即退出

# ---------- 颜色输出 ----------
red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

# ---------- Git 稀疏克隆 ----------
git_sparse_clone() {
    branch="$1" repourl="$2" && shift 2
    git clone --depth=1 -b "$branch" --single-branch --filter=blob:none --sparse "$repourl"
    repodir=$(basename "$repourl" .git)
    cd "$repodir"
    git sparse-checkout set "$@"
    # 将需要的文件/目录移动到 package 下
    for item in "$@"; do
        if [ -e "$item" ]; then
            mv -f "$item" "../package/"
        else
            yellow "⚠️ 稀疏克隆未找到 $item，跳过"
        fi
    done
    cd ..
    rm -rf "$repodir"
}

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
# 假设仓库目录结构为 luci-app-adguardhome/ 整个应用
git clone --depth=1 -b master https://github.com/kongfl888/luci-app-adguardhome package/luci-app-adguardhome-tmp

# 重命名目录
mv package/luci-app-adguardhome-tmp package/luci-app-adguardhome-kong

# 3. 修改 Makefile 中的包名（如果存在）
MAKEFILE="package/luci-app-adguardhome-kong/Makefile"
if [ -f "$MAKEFILE" ]; then
    # 将 PKG_NAME 改为 luci-app-adguardhome-kong，同时保留版本号等
    sed -i 's/^PKG_NAME:=.*/PKG_NAME:=luci-app-adguardhome-kong/' "$MAKEFILE"
    green "✅ 已修改 Makefile 中的 PKG_NAME"
else
    yellow "⚠️ Makefile 不存在，请手动检查包名"
fi

# 4. 更新 feeds
green "🔄 更新 feeds..."
./scripts/feeds update -a
./scripts/feeds install -a

# 5. 预置 AdGuardHome 核心（arm64）
green "⬇️ 预置 AdGuardHome 核心（arm64）..."
mkdir -p files/usr/bin
# 使用 jq 解析 JSON（需安装 jq），若无则用 grep 兼容方案
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

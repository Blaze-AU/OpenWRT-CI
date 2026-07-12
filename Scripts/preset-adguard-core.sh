#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 拉取 kongfl888 版到 package/ 下，并重命名包名，避免与官方冲突

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

clone_and_rename() {
    local repo="$1"
    local branch="$2"
    local custom_pkg_name="luci-app-adguardhome-kong"
    local repo_name="${repo#*/}"

    # 1. 清理旧的 package 目录
    echo "正在清理旧的 package 目录 ..."
    rm -rf "package/$custom_pkg_name"
    rm -rf "package/$repo_name"

    # 2. 克隆自定义源码到临时目录
    mkdir -p package
    echo "正在克隆 $repo (分支 $branch) ..."
    if ! git clone --depth=1 --single-branch --branch "$branch" "https://github.com/$repo.git" "package/$repo_name"; then
        red "❌ 克隆失败，尝试 master"
        if ! git clone --depth=1 --single-branch --branch master "https://github.com/$repo.git" "package/$repo_name"; then
            red "❌ 克隆失败"
            return 1
        fi
    fi

    # 3. 重命名目录并修改 Makefile
    echo "正在重命名包名并修改 Makefile ..."
    mv "package/$repo_name" "package/$custom_pkg_name"
    local makefile="package/$custom_pkg_name/Makefile"
    if [[ -f "$makefile" ]]; then
        # 修改 PKG_NAME
        sed -i 's/^PKG_NAME:=.*/PKG_NAME:=luci-app-adguardhome-kong/' "$makefile"
        # 修改 PKG_VERSION 以便识别
        sed -i 's/^PKG_VERSION:=.*/PKG_VERSION:=v1.8-kongfl888/' "$makefile"
        # 移除对 adguardhome 的依赖
        sed -i 's/+adguardhome\b[^ ]*//g' "$makefile"
        sed -i 's/, \+/ /g; s/ \+/, /g; s/,,*/,/g; s/,$//g' "$makefile"
        # 修改标题（可选）
        sed -i 's/TITLE:=.*/TITLE:=AdGuardHome (kongfl888 version)/' "$makefile"
        green "✅ Makefile 已修改"
    else
        yellow "⚠️ Makefile 不存在，请检查仓库结构"
        return 1
    fi

    # 4. 清理 feeds 中的官方包（避免冲突）
    echo "正在清理 feeds 中的官方包 ..."
    ./scripts/feeds uninstall luci-app-adguardhome 2>/dev/null || true
    ./scripts/feeds uninstall adguardhome 2>/dev/null || true
    rm -rf feeds/luci/applications/luci-app-adguardhome
    rm -rf feeds/packages/net/adguardhome
    rm -f feeds/luci.index feeds/packages.index
    # 强制刷新索引（仅更新，不安装）
    ./scripts/feeds update -i 2>/dev/null || true

    # 5. 清理编译缓存
    echo "正在清理编译缓存 ..."
    make package/luci-app-adguardhome/clean 2>/dev/null || true
    rm -rf tmp/

    green "✅ 自定义包已准备：$custom_pkg_name"
    return 0
}

# ---------- 主流程 ----------
green "========================================="
green "AdGuardHome 自定义包（kongfl888 版）"
green "包名改为 luci-app-adguardhome-kong"
green "========================================="

BRANCH="master"
green "将使用分支: $BRANCH"

if ! clone_and_rename "kongfl888/luci-app-adguardhome" "$BRANCH"; then
    red "❌ 操作失败"
    exit 1
fi

# 预置核心（arm64）
green "=== 预置 AdGuardHome 核心 ==="
mkdir -p files/usr/bin
AGH_URL=$(curl -sL https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep -oP '"browser_download_url":\s*"\K[^"]*linux_arm64[^"]*' | head -1)
if [[ -n "$AGH_URL" ]]; then
    wget -qO- "$AGH_URL" | tar -xOz --wildcards '*/AdGuardHome' > files/usr/bin/AdGuardHome 2>/dev/null && {
        chmod +x files/usr/bin/AdGuardHome
        green "✅ 核心下载成功"
    } || yellow "⚠️ 核心下载失败"
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

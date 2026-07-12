#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# ---------- 拉取源码 ----------
clone_adg() {
    local repo="$1"
    local branch="$2"
    local pkg_name="luci-app-adguardhome"
    local repo_name="${repo#*/}"

    # 1. 卸载 feeds 中的官方包（避免索引残留）
    echo "正在卸载 feeds 中的官方包 ..."
    ./scripts/feeds uninstall "$pkg_name" 2>/dev/null || true
    ./scripts/feeds uninstall "adguardhome" 2>/dev/null || true

    # 2. 精确删除 feeds 中的官方包目录
    echo "正在删除 feeds 中的官方目录 ..."
    rm -rf feeds/luci/applications/luci-app-adguardhome
    rm -rf feeds/packages/net/adguardhome
    rm -rf package/feeds/luci/luci-app-adguardhome
    rm -rf package/feeds/packages/adguardhome

    # 3. 扩展删除所有相关目录
    echo "正在删除所有相关目录 ..."
    for name in "$pkg_name" "adguardhome"; do
        find feeds/luci/ feeds/packages/ package/ -maxdepth 4 -type d -iname "*$name*" -exec rm -rf {} + 2>/dev/null || true
        [[ -d "$name" ]] && rm -rf "$name"
    done

    # 4. 删除 feeds 索引文件
    echo "正在删除 feeds 索引文件 ..."
    rm -f feeds/luci.index feeds/packages.index

    # 5. 克隆自定义版本到 package/
    rm -rf "package/$repo_name"
    mkdir -p package
    echo "正在克隆 $pkg_name (https://github.com/$repo.git 分支 $branch) ..."
    if ! git clone --depth=1 --single-branch --branch "$branch" "https://github.com/$repo.git" "package/$repo_name"; then
        red "❌ 克隆失败，尝试使用默认分支 master"
        if ! git clone --depth=1 --single-branch --branch master "https://github.com/$repo.git" "package/$repo_name"; then
            red "❌ 克隆失败"
            return 1
        fi
    fi

    # 6. 移除核心依赖
    local makefile="package/$repo_name/Makefile"
    if [[ -f "$makefile" ]]; then
        sed -i 's/+adguardhome\b[^ ]*//g' "$makefile"
        sed -i 's/, \+/ /g; s/ \+/, /g; s/,,*/,/g; s/,$//g' "$makefile"
        green "✅ 已移除核心依赖"
    else
        yellow "⚠️ Makefile 不存在，请检查仓库结构"
    fi

    # 7. 将自定义包复制到 feeds 目录（强制覆盖官方位置）
    echo "正在将自定义包复制到 feeds 目录 ..."
    mkdir -p feeds/luci/applications
    rm -rf feeds/luci/applications/luci-app-adguardhome
    cp -r "package/$repo_name" feeds/luci/applications/luci-app-adguardhome

    # 8. 刷新 feeds 索引（重新生成，包含自定义包）
    echo "正在刷新 feeds 索引 ..."
    ./scripts/feeds update -i 2>/dev/null || true

    # 9. 清理编译缓存
    echo "正在清理编译缓存 ..."
    make package/luci-app-adguardhome/clean 2>/dev/null || true

    green "✅ 源码准备完成（自定义版已同时存在于 package/ 和 feeds/）"
    return 0
}

# ---------- 主流程 ----------
green "========================================="
green "AdGuardHome 源码替换 (官方 → kongfl888)"
green "强制覆盖 feeds 目录，确保使用自定义版本"
green "========================================="

BRANCH="master"
green "将使用分支: $BRANCH"

if ! clone_adg "kongfl888/luci-app-adguardhome" "$BRANCH"; then
    red "❌ 源码拉取失败，终止"
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
    } || yellow "⚠️ 核心下载失败（wget 或 tar 错误）"
else
    yellow "⚠️ 未找到 arm64 核心下载链接"
fi

green "========================================="
green "✅ AdGuardHome 源码替换完成"
green "  - 自定义版已放入 feeds/luci/applications/ 和 package/"
green "  - 分支: $BRANCH"
green "  - 核心依赖已移除"
green "  - 核心已预置（如成功下载）"
green "  - 重要: 现在运行 'make defconfig' 确认配置，然后正常编译"
green "========================================="
exit 0

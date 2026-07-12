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

    # 2. 精确删除 feeds 中的官方包目录（防止 find 深度不够）
    echo "正在删除 feeds 中的官方目录 ..."
    rm -rf feeds/luci/applications/luci-app-adguardhome
    rm -rf feeds/packages/net/adguardhome
    # 同时删除可能存在的 package/feeds 软链接残留
    rm -rf package/feeds/luci/luci-app-adguardhome
    rm -rf package/feeds/packages/adguardhome

    # 3. 扩展删除所有相关目录（更深层次）
    echo "正在删除所有相关目录 ..."
    for name in "$pkg_name" "adguardhome"; do
        # 移除 -maxdepth 限制或加大深度
        find feeds/luci/ feeds/packages/ package/ -maxdepth 4 -type d -iname "*$name*" -exec rm -rf {} + 2>/dev/null || true
        [[ -d "$name" ]] && rm -rf "$name"
    done

    # 4. 删除 feeds 索引文件（强制清除缓存）
    echo "正在删除 feeds 索引文件 ..."
    rm -f feeds/luci.index feeds/packages.index

    # 5. 确保 package 目标目录为空
    rm -rf "package/$repo_name"
    mkdir -p package

    # 6. 克隆 kongfl888 版本
    echo "正在克隆 $pkg_name (https://github.com/$repo.git 分支 $branch) ..."
    if ! git clone --depth=1 --single-branch --branch "$branch" "https://github.com/$repo.git" "package/$repo_name"; then
        red "❌ 克隆失败，尝试使用默认分支 master"
        if ! git clone --depth=1 --single-branch --branch master "https://github.com/$repo.git" "package/$repo_name"; then
            red "❌ 克隆失败"
            return 1
        fi
    fi

    # 7. 移除核心依赖（避免编译时再次下载核心）
    local makefile="package/$repo_name/Makefile"
    if [[ -f "$makefile" ]]; then
        # 移除 +adguardhome 及其后的依赖项
        sed -i 's/+adguardhome\b[^ ]*//g' "$makefile"
        # 清理多余逗号和空格，保持依赖列表格式整洁
        sed -i 's/, \+/ /g; s/ \+/, /g; s/,,*/,/g; s/,$//g' "$makefile"
        green "✅ 已移除核心依赖"
    else
        yellow "⚠️ Makefile 不存在，请检查仓库结构"
    fi

    # 8. 刷新 feeds 索引（只更新索引，不安装包）
    echo "正在刷新 feeds 索引 ..."
    ./scripts/feeds update -i 2>/dev/null || true

    # 9. 清理编译缓存（避免旧对象干扰）
    echo "正在清理编译缓存 ..."
    make package/luci-app-adguardhome/clean 2>/dev/null || true

    green "✅ 源码准备完成（包格式由系统决定）"
    return 0
}

# ---------- 主流程 ----------
green "========================================="
green "AdGuardHome 源码替换 (官方 → kongfl888)"
green "包格式由 OpenWrt 构建配置自动选择"
green "========================================="

# 设置默认分支（您可手动修改为其他 tag，如 v1.8-20221120）
BRANCH="master"
green "将使用分支: $BRANCH"

# 克隆源码
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
green "  - 官方源码已彻底移除，kongfl888 版已克隆"
green "  - 分支: $BRANCH"
green "  - 核心依赖已移除"
green "  - 核心已预置（如成功下载）"
green "  - 提示: 若之前编译过，请运行 'make clean' 或删除 tmp/ 目录"
green "========================================="
exit 0

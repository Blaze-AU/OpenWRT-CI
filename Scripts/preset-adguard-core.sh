#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 强制替换 feeds 中的 AdGuardHome 源码为 kongfl888 版

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# ---------- 拉取并覆盖源码 ----------
clone_and_override() {
    local repo="$1"
    local branch="$2"
    local pkg_name="luci-app-adguardhome"
    local repo_name="${repo#*/}"

    # 1. 卸载 feeds 中的包
    echo "正在卸载 feeds 中的官方包 ..."
    ./scripts/feeds uninstall "$pkg_name" 2>/dev/null || true
    ./scripts/feeds uninstall "adguardhome" 2>/dev/null || true

    # 2. 删除所有相关目录（包括 package/ 和 feeds/）
    echo "正在删除所有相关目录 ..."
    rm -rf "package/$repo_name"
    rm -rf feeds/luci/applications/luci-app-adguardhome
    rm -rf feeds/packages/net/adguardhome
    rm -rf package/feeds/luci/luci-app-adguardhome
    rm -rf package/feeds/packages/adguardhome
    # 用 find 清理可能残留的深层目录
    find . -type d -iname "*$pkg_name*" -exec rm -rf {} + 2>/dev/null || true
    find . -type d -iname "adguardhome" -exec rm -rf {} + 2>/dev/null || true

    # 3. 删除 feeds 索引和 tmp 缓存（强制刷新）
    echo "正在删除 feeds 索引和构建缓存 ..."
    rm -f feeds/luci.index feeds/packages.index
    rm -rf tmp/

    # 4. 克隆自定义版本到 package/ 目录
    mkdir -p package
    echo "正在克隆 $pkg_name (https://github.com/$repo.git 分支 $branch) ..."
    if ! git clone --depth=1 --single-branch --branch "$branch" "https://github.com/$repo.git" "package/$repo_name"; then
        red "❌ 克隆失败，尝试默认分支 master"
        if ! git clone --depth=1 --single-branch --branch master "https://github.com/$repo.git" "package/$repo_name"; then
            red "❌ 克隆失败"
            return 1
        fi
    fi

    # 5. 修改 Makefile：移除核心依赖 + 修改 PKG_VERSION 以区分官方
    local makefile="package/$repo_name/Makefile"
    if [[ -f "$makefile" ]]; then
        # 移除 +adguardhome 依赖
        sed -i 's/+adguardhome\b[^ ]*//g' "$makefile"
        sed -i 's/, \+/ /g; s/ \+/, /g; s/,,*/,/g; s/,$//g' "$makefile"

        # 修改 PKG_VERSION 追加 "-kongfl888" 以强制区分官方版本
        if grep -q "^PKG_VERSION:=" "$makefile"; then
            sed -i 's/^PKG_VERSION:=.*/PKG_VERSION:=v1.8-kongfl888/' "$makefile"
        else
            # 若没有则插入
            sed -i '/include $(TOPDIR)\/rules.mk/a PKG_VERSION:=v1.8-kongfl888' "$makefile"
        fi
        green "✅ 已移除核心依赖并修改 PKG_VERSION"
    else
        yellow "⚠️ Makefile 不存在"
        return 1
    fi

    # 6. 将自定义包复制到 feeds 目录（覆盖官方位置）
    echo "正在覆盖 feeds 中的官方包 ..."
    mkdir -p feeds/luci/applications
    rm -rf feeds/luci/applications/luci-app-adguardhome
    cp -r "package/$repo_name" feeds/luci/applications/luci-app-adguardhome

    # 7. 重新生成 feeds 索引（使用 -i 仅更新索引）
    echo "正在重新生成 feeds 索引 ..."
    ./scripts/feeds update -i 2>/dev/null || true

    # 8. 强制清理该包的构建产物
    echo "正在清理编译缓存 ..."
    make package/luci-app-adguardhome/clean 2>/dev/null || true
    rm -rf build_dir/target-*/luci-app-adguardhome
    rm -rf staging_dir/target-*/pkginfo/*adguardhome*

    green "✅ 源码替换完成（自定义版已同时存在于 package/ 和 feeds/）"
    return 0
}

# ---------- 主流程 ----------
green "========================================="
green "强制替换 AdGuardHome 源码为 kongfl888 版"
green "========================================="

BRANCH="master"
green "将使用分支: $BRANCH"

if ! clone_and_override "kongfl888/luci-app-adguardhome" "$BRANCH"; then
    red "❌ 操作失败，终止"
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
green "✅ 所有操作完成"
green "  - 自定义版已强制覆盖 feeds 和 package"
green "  - PKG_VERSION 已修改为 v1.8-kongfl888"
green "  - 核心已预置（如成功）"
green ""
yellow "⚠️ 重要：请立即执行以下命令以生效："
yellow "  1. make defconfig"
yellow "  2. make package/luci-app-adguardhome/compile V=s"
yellow "  检查编译日志中的 'PKG_VERSION' 是否为 v1.8-kongfl888"
green "========================================="
exit 0

#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# AdGuardHome 源码拉取 (kongfl888 版) + 核心预置
# 不强制指定包格式，由 OpenWrt 构建系统自动决定 (ipk/apk)

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# ---------- 拉取源码 ----------
clone_adg() {
    local repo="$1"
    local branch="$2"
    local pkg_name="luci-app-adguardhome"
    local repo_name="${repo#*/}"

    # 清理旧目录（界面 + 核心）
    for name in "$pkg_name" "adguardhome"; do
        find feeds/luci/ feeds/packages/ package/ -maxdepth 3 -type d -iname "*$name*" -exec rm -rf {} + 2>/dev/null || true
        [[ -d "$name" ]] && rm -rf "$name"
    done

    mkdir -p package

    echo "正在克隆 $pkg_name (https://github.com/$repo.git 分支 $branch) ..."
    if ! git clone --depth=1 --single-branch --branch "$branch" "https://github.com/$repo.git" "package/$repo_name"; then
        red "❌ 克隆失败，尝试使用默认分支 master"
        if ! git clone --depth=1 --single-branch --branch master "https://github.com/$repo.git" "package/$repo_name"; then
            red "❌ 克隆失败"
            return 1
        fi
    fi

    # 移除核心依赖（避免编译时再次下载核心）
    local makefile="package/$repo_name/Makefile"
    if [[ -f "$makefile" ]]; then
        # 移除 +adguardhome 及其后的依赖项
        sed -i 's/+adguardhome\b[^ ]*//g' "$makefile"
        # 清理多余逗号和空格，保持依赖列表格式整洁
        sed -i 's/, \+/ /g; s/ \+/, /g; s/,,*/,/g; s/,$//g' "$makefile"
        green "✅ 已移除核心依赖"

        # 注意：此处不再强行指定 PKG_EXT，包格式由 OpenWrt 全局配置决定
    else
        yellow "⚠️ Makefile 不存在，请检查仓库结构"
    fi

    # 清理 feeds 索引（避免冲突）
    find feeds/luci/ -maxdepth 2 -type f -name "Makefile" -exec grep -l "PKG_NAME:=luci-app-adguardhome" {} \; 2>/dev/null | while read -r idx; do
        sed -i '/^define Package\/luci-app-adguardhome/,/^endef/d' "$idx"
        sed -i '/^PKG_NAME:=luci-app-adguardhome/d' "$idx"
    done || true

    green "✅ 源码准备完成（包格式由系统决定）"
    return 0
}

# ---------- 主流程 ----------
green "========================================="
green "AdGuardHome 源码拉取 (kongfl888) + 核心预置"
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
green "✅ AdGuardHome 源码 + 核心准备完成"
green "  - 仓库: kongfl888/luci-app-adguardhome"
green "  - 分支: $BRANCH"
green "  - 核心依赖已移除"
green "  - 核心已预置（如成功下载）"
green "  - 包格式: 由 .config 中的 CONFIG_PACKAGE_FORMAT_* 决定"
green "  - 编译命令: make package/luci-app-adguardhome/compile V=s"
green "  - 注意：.config 配置由 Settings.sh 负责"
green "========================================="
exit 0

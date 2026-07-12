#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# AdGuardHome 源码拉取 + 核心预置（不修改 .config）

green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
red() { echo -e "\033[31m$1\033[0m"; }

# 自动切换到 OpenWRT 根目录
if [[ -f "feeds.conf.default" ]]; then
    :
elif [[ -f "../feeds.conf.default" ]]; then
    cd ..
elif [[ -f "../../feeds.conf.default" ]]; then
    cd ../..
else
    echo "❌ 找不到 feeds.conf.default"
    exit 1
fi
echo "📍 当前工作目录：$(pwd)"

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

    echo "正在克隆 $pkg_name (https://github.com/$repo.git tag $branch) ..."
    if ! git clone --depth=1 --single-branch --branch "$branch" "https://github.com/$repo.git" "package/$repo_name"; then
        red "❌ 克隆失败"
        return 1
    fi

    # 移除核心依赖
    local makefile="package/$repo_name/Makefile"
    if [[ -f "$makefile" ]]; then
        sed -i 's/+adguardhome\b[^ ]*//g' "$makefile"
        sed -i 's/, \+/ /g; s/ \+/, /g; s/,,*/,/g; s/,$//g' "$makefile"
        green "✅ 已移除核心依赖"
    else
        yellow "⚠️ Makefile 不存在"
    fi

    # 清理 feeds 索引（避免冲突）
    find feeds/luci/ -maxdepth 2 -type f -name "Makefile" -exec grep -l "PKG_NAME:=luci-app-adguardhome" {} \; 2>/dev/null | while read -r idx; do
        sed -i '/^define Package\/luci-app-adguardhome/,/^endef/d' "$idx"
        sed -i '/^PKG_NAME:=luci-app-adguardhome/d' "$idx"
    done || true

    green "✅ 源码准备完成"
    return 0
}

# ---------- 主流程 ----------
green "========================================="
green "AdGuardHome 源码拉取 + 核心预置"
green "========================================="

# 1. 获取最新 Tag
LATEST_TAG=$(curl -sL https://api.github.com/repos/stevenjoezhang/luci-app-adguardhome/releases/latest | jq -r '.tag_name' 2>/dev/null)
[[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]] && LATEST_TAG="v1.19"
green "将使用版本: $LATEST_TAG"

# 2. 克隆源码（必须成功）
if ! clone_adg "stevenjoezhang/luci-app-adguardhome" "$LATEST_TAG"; then
    red "❌ 源码拉取失败，终止"
    exit 1
fi

# 3. 尝试 feeds install（忽略失败）
./scripts/feeds install luci-app-adguardhome 2>/dev/null || true

# 4. 预置核心（arm64）
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
green "✅ AdGuardHome 源码 + 核心准备完成"
green "  - 版本: $LATEST_TAG"
green "  - 核心依赖已移除"
green "  - 核心已预置（如成功下载）"
green "  - 注意：.config 配置由 Settings.sh 负责"
green "========================================="
exit 0

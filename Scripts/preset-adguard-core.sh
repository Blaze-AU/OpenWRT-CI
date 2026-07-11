#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 强制安装 AdGuardHome：无视 .config 原有状态，直接拉取并强制编译

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

# ---------- 工具函数 ----------
# 清理并拉取
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

# 强制写入 .config（无论之前是什么）
force_enable() {
    sed -i "/^CONFIG_PACKAGE_luci-app-adguardhome=/d" ./.config
    echo "CONFIG_PACKAGE_luci-app-adguardhome=y" >> ./.config
    sed -i "/^CONFIG_PACKAGE_adguardhome=/d" ./.config
    sed -i "/^# CONFIG_PACKAGE_adguardhome/d" ./.config
    echo "# CONFIG_PACKAGE_adguardhome is not set" >> ./.config
}

# ---------- 主流程 ----------
green "========================================="
green "强制安装 AdGuardHome（不依赖原 .config）"
green "========================================="

# 1. 获取最新 Tag（备用 v1.19）
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

# 4. 强制写入 .config（第一次）
green "=== 强制写入 .config（前） ==="
force_enable

# 5. 运行 defconfig（可能重置，但我们会再次强制）
green "=== 运行 defconfig（忽略失败） ==="
make defconfig 2>/dev/null || true

# 6. 再次强制写入 .config（确保未被重置）
green "=== 强制写入 .config（后） ==="
force_enable

# 7. 最终验证并追加（确保万无一失）
if ! grep -q "^CONFIG_PACKAGE_luci-app-adguardhome=y" ./.config; then
    echo "CONFIG_PACKAGE_luci-app-adguardhome=y" >> ./.config
fi
if grep -q "^CONFIG_PACKAGE_adguardhome=y" ./.config; then
    sed -i "/^CONFIG_PACKAGE_adguardhome=/d" ./.config
    echo "# CONFIG_PACKAGE_adguardhome is not set" >> ./.config
fi

green "✅ .config 已强制包含 luci-app-adguardhome"

# 8. 预置核心（arm64，可选）
green "=== 预置 AdGuardHome 核心 ==="
mkdir -p files/usr/bin
AGH_URL=$(curl -sL https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest | grep -oP '"browser_download_url":\s*"\K[^"]*linux_arm64[^"]*' | head -1)
if [[ -n "$AGH_URL" ]]; then
    wget -qO- "$AGH_URL" | tar -xOz --wildcards '*/AdGuardHome' > files/usr/bin/AdGuardHome 2>/dev/null && {
        chmod +x files/usr/bin/AdGuardHome
        green "✅ 核心下载成功"
    } || yellow "⚠️ 核心下载失败，编译时可能自动下载"
else
    yellow "⚠️ 未找到 arm64 核心下载链接"
fi

green "========================================="
green "✅ AdGuardHome 强制安装流程完成"
green "  - 源码已拉取（$LATEST_TAG）"
green "  - 核心依赖已移除"
green "  - .config 已强制启用界面、禁用核心"
green "  - 即使有警告，编译时将包含该包"
green "========================================="
exit 0

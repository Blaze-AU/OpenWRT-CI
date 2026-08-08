#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
# 仅下载 AdGuardHome 核心，无 UPX，自动架构，默认获取最新版本

set -e

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

# ---------- 版本设置 ----------
# 默认获取最新版本（latest），如需固定版本可设为 "v0.107.78" 等
AGH_VERSION="${AGH_VERSION:-latest}"

# ---------- 依赖检查 ----------
for cmd in wget curl tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        red "❌ 缺少依赖命令: $cmd"
        exit 1
    fi
done

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

# ---------- 检测目标架构（从 .config 或环境变量） ----------
detect_arch() {
    if [ -f ".config" ]; then
        local arch=$(grep -E "^(CONFIG_ARCH=|CONFIG_TARGET_ARCH_PACKAGES=)" .config | head -1 | cut -d'=' -f2 | tr -d '"')
        case "$arch" in
            aarch64*|arm64*)   echo "arm64" ;;
            x86_64|amd64)      echo "amd64" ;;
            armv7*|armv7l)     echo "armv7" ;;
            armv6*|armv6l)     echo "armv6" ;;
            *)                 echo "${TARGET_ARCH:-arm64}" ;;
        esac
    else
        echo "${TARGET_ARCH:-arm64}"
    fi
}

ARCH=$(detect_arch)
green "🖥️  目标架构: $ARCH"

# ---------- 预置核心 ----------
green "⬇️  预置 AdGuardHome 核心 ($ARCH) 版本: $AGH_VERSION ..."

BIN_DIR="files/usr/bin/AdGuardHome"
BIN_PATH="$BIN_DIR/AdGuardHome"
mkdir -p "$BIN_DIR"

if [ -s "$BIN_PATH" ]; then
    green "✅ 核心已存在，跳过下载 ($(du -h "$BIN_PATH" | cut -f1))"
    exit 0
fi

case "$ARCH" in
    arm64)  SUFFIX="linux_arm64" ;;
    amd64)  SUFFIX="linux_amd64" ;;
    armv7)  SUFFIX="linux_armv7" ;;
    armv6)  SUFFIX="linux_armv6" ;;
    *)      yellow "⚠️ 未知架构 $ARCH，尝试 linux_arm64"; SUFFIX="linux_arm64" ;;
esac

# ---------- 获取下载 URL ----------
if [ "$AGH_VERSION" = "latest" ]; then
    API_URL="https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest"
else
    API_URL="https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/tags/${AGH_VERSION}"
fi

if command -v jq >/dev/null 2>&1; then
    AGH_URL=$(curl -sL "$API_URL" \
        | jq -r ".assets[] | select(.name | contains(\"${SUFFIX}.tar.gz\")) | .browser_download_url" | head -1)
else
    AGH_URL=$(curl -sL "$API_URL" \
        | grep -o '"browser_download_url":\s*"[^"]*'${SUFFIX}'\.tar\.gz[^"]*"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')
fi

if [ -z "$AGH_URL" ]; then
    yellow "⚠️ 未找到 ${SUFFIX} 核心的下载链接（版本 $AGH_VERSION），跳过预置"
    exit 0
fi

# ---------- 下载并解压 ----------
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

green "📥 下载地址: $AGH_URL"
if wget -q --show-progress "$AGH_URL" -O "$TMP_DIR/agh.tar.gz"; then
    tar -xzf "$TMP_DIR/agh.tar.gz" -C "$TMP_DIR"
    # 兼容 BusyBox：直接按文件名查找，不依赖 -perm（之后会 chmod +x）
    SRC_BIN=$(find "$TMP_DIR" -type f -name "AdGuardHome" | head -1)
    if [ -n "$SRC_BIN" ] && [ -s "$SRC_BIN" ]; then
        mv "$SRC_BIN" "$BIN_PATH"
        chmod +x "$BIN_PATH"
        green "✅ 核心下载成功 ($(du -h "$BIN_PATH" | cut -f1))"
    else
        yellow "⚠️ 解压后未找到可执行文件"
        rm -f "$BIN_PATH"
    fi
else
    yellow "⚠️ 核心下载失败（请检查网络或 GitHub 访问）"
fi

# ---------- 完成提示 ----------
green "========================================="
green "✅ 准备完成！"
green "核心版本: $AGH_VERSION"
green "核心路径: $BIN_PATH (固件内对应 /usr/bin/AdGuardHome/AdGuardHome)"
green "配置路径: /etc/AdGuardHome.yaml"
green "工作目录: /usr/bin/AdGuardHome"
green "日志路径: /tmp/AdGuardHome.log"
green "========================================="
green "下一步："
green "  1. 运行 'make menuconfig' 并选择 'luci-app-adguardhome'"
green "  2. 运行 'make V=s' 编译固件"
green "========================================="
exit 0

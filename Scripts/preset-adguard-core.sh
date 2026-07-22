#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

set -e

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }

# ---------- 主流程 ----------
green "==================================="

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
green "========================================="
exit 0

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
set -Eeuo pipefail

# ============================================================
# 
# Git 稀疏克隆，只克隆指定目录到本地
git_sparse_clone() {
  local branch="$1"
  local repourl="$2"
  local repodir
  local sparse_path
  shift 2

  repodir="$(basename "${repourl%.git}")"
  clone_with_retry "$repodir" \
    --depth=1 \
    --no-tags \
    --branch "$branch" \
    --single-branch \
    --filter=blob:none \
    --sparse \
    "$repourl"
  (
    cd "$repodir"
    git sparse-checkout set "$@"
  )
  record_git_revision "$repourl" "$branch" "$repodir"

  for sparse_path in "$@"; do
    rm -rf "package/$(basename "$sparse_path")"
    mv "$repodir/$sparse_path" package/
  done
  rm -rf "$repodir"
}

# ============================================================
# 五、初始化第三方源版本记录文件
# ============================================================
mkdir -p "$(dirname "$THIRD_PARTY_SOURCES_FILE")"
printf 'Repository\tBranch\tCommit\n' > "$THIRD_PARTY_SOURCES_FILE"

# ============================================================
# 六、按需拉取第三方包（只拉配置里启用的）
# ============================================================
green "==== 按需拉取第三方包 ===="

# ---- UPNP（含 miniupnpd 依赖）----
if package_enabled luci-app-upnp miniupnpd; then
  rm -rf feeds/packages/net/miniupnpd
  git_sparse_clone master https://github.com/immortalwrt/packages net/miniupnpd
  mv package/miniupnpd feeds/packages/net/miniupnpd
fi
if package_enabled luci-app-upnp; then
  rm -rf feeds/luci/applications/luci-app-upnp
  git_sparse_clone master https://github.com/immortalwrt/luci applications/luci-app-upnp
  mv package/luci-app-upnp feeds/luci/applications/luci-app-upnp
fi

# ---- WOL ----
if package_enabled luci-app-wol; then
  rm -rf feeds/luci/applications/luci-app-wol
  git_sparse_clone master https://github.com/immortalwrt/luci applications/luci-app-wol
  mv package/luci-app-wol feeds/luci/applications/luci-app-wol
fi

# ---- Argon 主题 + 配置 ----
if package_enabled luci-theme-argon luci-app-argon-config; then
  rm -rf feeds/luci/themes/luci-theme-argon
  clone_repository https://github.com/jerrykuku/luci-theme-argon master feeds/luci/themes/luci-theme-argon
fi
if package_enabled luci-app-argon-config; then
  rm -rf feeds/luci/applications/luci-app-argon-config
  clone_repository https://github.com/jerrykuku/luci-app-argon-config master feeds/luci/applications/luci-app-argon-config
fi

# ---- Aurora 主题 + 配置 ----
if package_enabled luci-theme-aurora luci-app-aurora-config; then
  rm -rf feeds/luci/themes/luci-theme-aurora
  clone_repository https://github.com/eamonxg/luci-theme-aurora master feeds/luci/themes/luci-theme-aurora
fi
if package_enabled luci-app-aurora-config; then
  rm -rf feeds/luci/applications/luci-app-aurora-config
  clone_repository https://github.com/eamonxg/luci-app-aurora-config master feeds/luci/applications/luci-app-aurora-config
fi

# ---- 微信推送 ----
if package_enabled luci-app-wechatpush; then
  rm -rf feeds/luci/applications/luci-app-wechatpush
  clone_repository https://github.com/tty228/luci-app-wechatpush master package/luci-app-wechatpush
fi

# ---- AdGuard Home ----
if package_enabled luci-app-adguardhome; then
  rm -rf feeds/luci/applications/luci-app-adguardhome
  git_sparse_clone master https://github.com/kenzok8/openwrt-packages luci-app-adguardhome
  mv package/luci-app-adguardhome feeds/luci/applications/luci-app-adguardhome
fi

# ---- SmartDNS ----
if package_enabled luci-app-smartdns; then
  rm -rf feeds/luci/applications/luci-app-smartdns
  git_sparse_clone master https://github.com/kenzok8/openwrt-packages luci-app-smartdns
  mv package/luci-app-smartdns feeds/luci/applications/luci-app-smartdns
fi

# ============================================================
# 七、完成
# ============================================================
green "==== 第三方包拉取完成 ===="
green "版本记录：$THIRD_PARTY_SOURCES_FILE"

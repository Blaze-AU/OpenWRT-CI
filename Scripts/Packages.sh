#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY
set -Eeuo pipefail

# ============================================================
# 一、全局变量
# ============================================================
WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# 设备配置：优先第1参数 → CONFIG_FILE 环境变量 → 根据 WRT_CONFIG 自动推断
if [ -n "${1:-}" ]; then
  DEVICE_CONFIG_FILE="$1"
elif [ -n "${CONFIG_FILE:-}" ]; then
  DEVICE_CONFIG_FILE="$CONFIG_FILE"
elif [ -n "${WRT_CONFIG:-}" ]; then
  DEVICE_CONFIG_FILE="$WORKSPACE/Config/${WRT_CONFIG}.txt"
else
  DEVICE_CONFIG_FILE=""
fi

# 通用配置：优先第2参数 → GENERAL_CONFIG_FILE 环境变量 → 默认 Config/GENERAL.txt
GENERAL_CONFIG_FILE="${2:-${GENERAL_CONFIG_FILE:-$WORKSPACE/Config/GENERAL.txt}}"

GIT_CLONE_RETRY_COUNT="${GIT_CLONE_RETRY_COUNT:-3}"
THIRD_PARTY_SOURCES_FILE="${THIRD_PARTY_SOURCES_FILE:-$PWD/third-party-sources.txt}"

case "$GIT_CLONE_RETRY_COUNT" in
  '' | *[!0-9]* | 0)
    echo "Error: GIT_CLONE_RETRY_COUNT must be a positive integer" >&2
    exit 1
    ;;
esac

green() { echo -e "\033[32m$*\033[0m"; }

# ============================================================
# 二、配置文件解析
# ============================================================
resolve_config_file() {
  local config_file="$1"

  if [ -f "$config_file" ]; then
    printf '%s\n' "$config_file"
  elif [ -f "$WORKSPACE/$config_file" ]; then
    printf '%s\n' "$WORKSPACE/$config_file"
  else
    echo "Error: configuration file was not found: $config_file" >&2
    return 1
  fi
}

CONFIG_FILES=()
if [ -n "$DEVICE_CONFIG_FILE" ]; then
  CONFIG_FILES+=("$(resolve_config_file "$DEVICE_CONFIG_FILE")")
elif [ -f .config ]; then
  CONFIG_FILES+=("$PWD/.config")
else
  echo "Error: pass the device config as the first argument or CONFIG_FILE" >&2
  exit 1
fi
CONFIG_FILES+=("$(resolve_config_file "$GENERAL_CONFIG_FILE")")

# ============================================================
# 三、判断某个包是否在配置中启用
# ============================================================
config_symbol_enabled() {
  local symbol="$1"

  awk -v symbol="$symbol" '
    { sub(/\r$/, "") }
    $0 == symbol "=y" || $0 == symbol "=m" { enabled = 1; next }
    $0 == symbol "=n" || $0 == "# " symbol " is not set" { enabled = 0 }
    END { exit(enabled ? 0 : 1) }
  ' "${CONFIG_FILES[@]}"
}

target_device_package_enabled() {
  local package_name="$1"

  awk -v package_name="$package_name" '
    { sub(/\r$/, "") }
    /^CONFIG_TARGET_DEVICE_PACKAGES_[^=]+="/ {
      packages = $0
      sub(/^[^"]*"/, "", packages)
      sub(/"$/, "", packages)
      count = split(packages, values, /[[:space:]]+/)
      for (i = 1; i <= count; i++) {
        if (values[i] == package_name) {
          found = 1
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${CONFIG_FILES[@]}"
}

package_enabled() {
  local package_name

  for package_name in "$@"; do
    if config_symbol_enabled "CONFIG_PACKAGE_$package_name" || target_device_package_enabled "$package_name"; then
      return 0
    fi
  done

  return 1
}

# ============================================================
# 四、克隆工具（重试 + 版本记录 + 稀疏克隆）
# ============================================================
clone_with_retry() {
  local target_dir="$1"
  local attempt
  shift

  for ((attempt = 1; attempt <= GIT_CLONE_RETRY_COUNT; attempt++)); do
    rm -rf "$target_dir"
    if git clone "$@" "$target_dir"; then
      return 0
    fi

    if [ "$attempt" -lt "$GIT_CLONE_RETRY_COUNT" ]; then
      echo "Git clone failed; retrying ($((attempt + 1))/$GIT_CLONE_RETRY_COUNT): ${*: -1}" >&2
      sleep $((attempt * 2))
    fi
  done

  echo "Error: git clone failed after $GIT_CLONE_RETRY_COUNT attempts: ${*: -1}" >&2
  return 1
}

record_git_revision() {
  local repo_url="$1"
  local branch="$2"
  local checkout_dir="$3"
  local commit
  local revision

  commit="$(git -C "$checkout_dir" rev-parse HEAD)"
  printf -v revision '%s\t%s\t%s' "$repo_url" "$branch" "$commit"
  grep -Fqx -- "$revision" "$THIRD_PARTY_SOURCES_FILE" || printf '%s\n' "$revision" >> "$THIRD_PARTY_SOURCES_FILE"
}

clone_repository() {
  local repo_url="$1"
  local branch="$2"
  local target_dir="$3"

  clone_with_retry "$target_dir" \
    --depth=1 \
    --no-tags \
    --branch "$branch" \
    --single-branch \
    "$repo_url"
  record_git_revision "$repo_url" "$branch" "$target_dir"
}

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

# ---- Aurora 主题 + 配置（修复：强制检查配置，确保源码一定到位）----
if config_symbol_enabled "CONFIG_PACKAGE_luci-theme-aurora" || \
   config_symbol_enabled "CONFIG_PACKAGE_luci-app-aurora-config" || \
   grep -q "CONFIG_PACKAGE_luci-theme-aurora=y" "${CONFIG_FILES[@]}" 2>/dev/null; then
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
# 七、重新生成 feeds 索引，确保新克隆的包被编译系统识别
# ============================================================
green "==== 更新 feeds 索引 ===="
if [ -x ./scripts/feeds ]; then
  ./scripts/feeds update -a || true
  ./scripts/feeds install -a || true
fi

# ============================================================
# 八、完成
# ============================================================
green "==== 第三方包拉取完成 ===="
green "版本记录：$THIRD_PARTY_SOURCES_FILE"

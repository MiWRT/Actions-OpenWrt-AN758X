#!/bin/bash
# ================================================================
# diy-part3.sh —— 拉取「可选插件（第二批）」到 package/custom
# 运行目录: ponwrt 源码根目录（feeds 安装之后、加载 .config 之前）
# 由 workflow 在 diy-part1.sh 之后调用。
#
# M1 分支版：Momo / EasyTier / Harbor File Pro / PartExp
#   + Aurora 主题 + Dufs（默认不编，保留选项）
#   Nikki 已关闭（改用 Momo），见 ADD_NIKKI=false
#
# configs/<机型>.config 里对应包 =y 的那几行指的就是本脚本。
# 本脚本缺失时，config 里勾了 =y 的包没有任何源码来源，
# make defconfig 会把未知符号静默剔除，编出来的固件里就没有这些软件。
# ================================================================

set -euo pipefail

echo "=========================================="
echo "拉取可选插件（第二批） (diy-part3.sh)"
echo "=========================================="

PKG_DIR="package/custom"
mkdir -p "$PKG_DIR"

# ---------------------------------------------------------
# 插件开关（M1：只开验证需要的 4 组；Nikki 已关，改用 Momo）
# ---------------------------------------------------------
ADD_NIKKI=true      # Nikki：透明代理（mihomo 内核）——已关闭，改用 Momo
                    #   ├─ luci-app-nikki   LuCI 界面（config 里 =y 的就是它）
                    #   ├─ nikki           核心脚本包（被 luci-app-nikki 依赖自动拉入）
                    #   └─ mihomo-meta     提供 mihomo（nikki DEPENDS 的 +mihomo，默认变体）
ADD_MOMO=false      # Momo：透明代理（sing-box 内核，与 Nikki 同作者 nikkinikki-org）
                    #   ├─ luci-app-momo   LuCI 界面（config 里 =y 的就是它）
                    #   ├─ momo           核心脚本包（被 luci-app-momo 依赖自动拉入）
                    #   └─ sing-box       代理内核（momo DEPENDS 的 +sing-box，由 feeds/packages 提供，无需拉源码）
                    # 注意：Momo 是 sing-box 方案，配置格式与 Nikki（mihomo YAML）不同，
                    # 不能直接沿用 Nikki 的订阅/配置文件，需用支持 sing-box 的订阅或手动转换。
ADD_EASYTIER=true   # EasyTier：组网 VPN
                    #   ├─ luci-app-easytier  LuCI 界面（config 里 =y 的就是它）
                    #   ├─ easytier         核心（含 Web 控制台；构建时下载官方预编译包并校验 SHA256）
                    #   └─ easytier-noweb   核心（无 Web 控制台，更小；与 easytier 互斥）
                    # 注意：luci-app-easytier 不依赖核心包，想让固件开箱即用，
                    # 必须在 config 里再加一行 CONFIG_PACKAGE_easytier=y
                    # （或 =easytier-noweb，两者只能选其一）
ADD_HARBOR=true      # Harbor File Pro：增强文件管理器（ucode 后端，需 OpenWrt 22.03+）
                    #   └─ luci-app-harbor-file-pro（单包；po 文件名需修正，见下拉取逻辑注释）
ADD_PARTEXP=true     # PartExp：分区格式化/扩容/自动挂载（sirpdboy）
                    #   └─ luci-app-partexp（单包；仓库根下 luci-app-partexp/ 就是包目录）
ADD_AURORA=true      # Aurora 主题：现代 LuCI 主题（Vite + Tailwind，需 OpenWrt 23.05+）
                    #   ├─ luci-theme-aurora（单包仓库，包在仓库根目录；自带 uci-defaults 设为默认主题）
                    #   └─ luci-app-aurora-config（主题配置 UI；po 文件名合规，无需改名）
ADD_DUFS=false       # Dufs：轻量文件服务器（zouzonghao）——默认不编，需要时手动开
                    #   └─ luci-app-dufs（单包仓库，包在仓库根目录；无 po 文件，无中文包）

clone() {  # clone <url> <dir> [branch]
  local url="$1" dir="$2" br="$3"
  [ -d "$dir" ] && { echo "已存在，跳过: $dir"; return 0; }
  echo "--- git clone $url -> $dir ---"
  if [ -n "$br" ]; then
    git clone --depth 1 -b "$br" "$url" "$dir" 2>&1 | tail -3
  else
    git clone --depth 1 "$url" "$dir" 2>&1 | tail -3
  fi
  if [ -d "$dir" ]; then
    echo "✅ 克隆成功: $dir"
    return 0
  fi
  echo "::error::克隆失败: $url"
  return 1
}

# =========================================================
# Nikki —— nikkinikki-org/OpenWrt-nikki（feed 结构）
# 根目录下是多个独立包：luci-app-nikki / nikki / mihomo-meta / mihomo-alpha
# 只拷需要的三个：
#   luci-app-nikki（LUCI_DEPENDS +nikki）-> 自动带入 nikki
#   nikki（DEPENDS +mihomo）              -> 由 mihomo-meta 的 PROVIDES:=mihomo 满足（默认变体）
# 不拷 mihomo-alpha：它和 mihomo-meta CONFLICTS，只能二选一
# =========================================================
if [ "$ADD_NIKKI" = "true" ]; then
  NIKKI_URL="https://github.com/nikkinikki-org/OpenWrt-nikki"
  NIKKI_TMP="$(mktemp -d)/nikki"

  if ! clone "$NIKKI_URL" "$NIKKI_TMP" main; then
    echo "::error::OpenWrt-nikki 拉取失败，luci-app-nikki / nikki 会被 defconfig 剔除"
    exit 1
  fi

  for p in nikki luci-app-nikki mihomo-meta; do
    if [ ! -f "$NIKKI_TMP/$p/Makefile" ]; then
      echo "::error::$NIKKI_TMP/$p/Makefile 不存在，包无法被索引"
      exit 1
    fi
    rm -rf "$PKG_DIR/$p"
    cp -r "$NIKKI_TMP/$p" "$PKG_DIR/"
    echo "✅ 已拷贝: $p"
  done

  rm -rf "$NIKKI_TMP"
fi

# =========================================================
# Momo —— nikkinikki-org/OpenWrt-momo（feed 结构，与 Nikki 同作者）
# 根目录下是两个独立包：momo / luci-app-momo
#   luci-app-momo（LUCI_DEPENDS +momo）-> 自动带入 momo
#   momo（DEPENDS +sing-box）           -> sing-box 由 feeds/packages 提供，无需拉源码
# 注意：不要和 Nikki 同时开——两者都是透明代理，会抢防火墙/nft 规则。
# =========================================================
if [ "$ADD_MOMO" = "true" ]; then
  MOMO_URL="https://github.com/nikkinikki-org/OpenWrt-momo"
  MOMO_TMP="$(mktemp -d)/momo"

  if ! clone "$MOMO_URL" "$MOMO_TMP" main; then
    echo "::error::OpenWrt-momo 拉取失败，luci-app-momo / momo 会被 defconfig 剔除"
    exit 1
  fi

  for p in momo luci-app-momo; do
    if [ ! -f "$MOMO_TMP/$p/Makefile" ]; then
      echo "::error::$MOMO_TMP/$p/Makefile 不存在，包无法被索引"
      exit 1
    fi
    rm -rf "$PKG_DIR/$p"
    cp -r "$MOMO_TMP/$p" "$PKG_DIR/"
    echo "✅ 已拷贝: $p"
  done

  rm -rf "$MOMO_TMP"
fi

# =========================================================

# =========================================================
# EasyTier —— zzwtsy/luci-app-easytier（feed 结构）
#   easytier/            核心（含 Web 控制台）
#   easytier-noweb/      核心（无 Web 控制台）
#   luci-app-easytier/   LuCI 界面（不依赖核心包，核心要在 config 里单独 =y）
#   version.mk           被 easytier*/Makefile 用 ../version.mk 引用，
#                        必须放在 package/custom/ 下（扫描器只找 Makefile，不会误认）
#
# 注意：easytier-noweb/Makefile 引用 ../easytier/common.mk，
# 所以即使只用 noweb 版，easytier/ 目录也要一起拷（只索引、不选中，无害）。
# =========================================================
if [ "$ADD_EASYTIER" = "true" ]; then
  ET_URL="https://github.com/zzwtsy/luci-app-easytier"
  ET_TMP="$(mktemp -d)/easytier"

  if ! clone "$ET_URL" "$ET_TMP" main; then
    echo "::error::luci-app-easytier 拉取失败，luci-app-easytier 会被 defconfig 剔除"
    exit 1
  fi

  if [ ! -f "$ET_TMP/version.mk" ]; then
    echo "::error::$ET_TMP/version.mk 不存在"
    exit 1
  fi
  cp "$ET_TMP/version.mk" "$PKG_DIR/version.mk"
  echo "✅ 已拷贝: version.mk -> $PKG_DIR/version.mk"

  for p in easytier easytier-noweb luci-app-easytier; do
    if [ ! -f "$ET_TMP/$p/Makefile" ]; then
      echo "::error::$ET_TMP/$p/Makefile 不存在，包无法被索引"
      exit 1
    fi
    rm -rf "$PKG_DIR/$p"
    cp -r "$ET_TMP/$p" "$PKG_DIR/"
    echo "✅ 已拷贝: $p"
  done

  rm -rf "$ET_TMP"
fi

# =========================================================

# =========================================================
# Harbor File Pro —— whzhni1/luci-app-harbor-file-pro
# 单包仓库：根下 luci-app-harbor-file-pro/ 就是包目录，直接拷。
#
# ⚠ po 文件名陷阱（同 diy-part1.sh 里 airoha-npu 的处理）：
#   上游 po 叫 harbor_file_pro.po，luci.mk 按 po 主名生成 lmo，
#   会得到 harbor_file_pro.zh-cn.lmo；但运行时按 LUCI_BASENAME
#   （luci-app-harbor-file-pro -> harbor-file-pro）查找，
#   对不上中文就不生效。改名为 harbor-file-pro.po 即可。
# =========================================================
if [ "$ADD_HARBOR" = "true" ]; then
  HARBOR_URL="https://github.com/whzhni1/luci-app-harbor-file-pro"
  HARBOR_TMP="$(mktemp -d)/harbor"

  if ! clone "$HARBOR_URL" "$HARBOR_TMP" main; then
    echo "::error::luci-app-harbor-file-pro 拉取失败，包会被 defconfig 剔除"
    exit 1
  fi

  if [ ! -f "$HARBOR_TMP/luci-app-harbor-file-pro/Makefile" ]; then
    echo "::error::$HARBOR_TMP/luci-app-harbor-file-pro/Makefile 不存在，包无法被索引"
    exit 1
  fi
  rm -rf "$PKG_DIR/luci-app-harbor-file-pro"
  cp -r "$HARBOR_TMP/luci-app-harbor-file-pro" "$PKG_DIR/"
  echo "✅ 已拷贝: luci-app-harbor-file-pro"

  # po 改名：harbor_file_pro.po -> harbor-file-pro.po（见上注释）
  HPO_DIR="$PKG_DIR/luci-app-harbor-file-pro/po"
  if [ -f "$HPO_DIR/zh_Hans/harbor_file_pro.po" ]; then
    mv "$HPO_DIR/zh_Hans/harbor_file_pro.po" "$HPO_DIR/zh_Hans/harbor-file-pro.po"
    echo "✅ po 改名: harbor_file_pro.po -> harbor-file-pro.po（luci.mk 按 LUCI_BASENAME 查找）"
  fi

  rm -rf "$HARBOR_TMP"
fi

# =========================================================

# =========================================================
# Aurora 主题 —— eamonxg/luci-theme-aurora
# 单包仓库：Makefile 就在仓库根目录，整个仓库（除 .git）就是包目录。
# 主题自带 root/etc/uci-defaults/30_luci-theme-aurora，首次安装会自动
# 把 luci.main.mediaurlbase 设为 /luci-static/aurora（即默认主题）。
# =========================================================
if [ "$ADD_AURORA" = "true" ]; then
  AURORA_URL="https://github.com/eamonxg/luci-theme-aurora"
  AURORA_TMP="$(mktemp -d)/aurora"

  if ! clone "$AURORA_URL" "$AURORA_TMP" master; then
    echo "::error::luci-theme-aurora 拉取失败，包会被 defconfig 剔除"
    exit 1
  fi

  if [ ! -f "$AURORA_TMP/Makefile" ]; then
    echo "::error::$AURORA_TMP/Makefile 不存在，包无法被索引"
    exit 1
  fi
  rm -rf "$PKG_DIR/luci-theme-aurora"
  mkdir -p "$PKG_DIR/luci-theme-aurora"
  cp -r "$AURORA_TMP"/. "$PKG_DIR/luci-theme-aurora/"
  rm -rf "$PKG_DIR/luci-theme-aurora/.git"
  echo "✅ 已拷贝: luci-theme-aurora"

  rm -rf "$AURORA_TMP"

  # 主题配置 UI（同作者，单包仓库，包在仓库根目录）
  AURORA_CFG_URL="https://github.com/eamonxg/luci-app-aurora-config"
  AURORA_CFG_TMP="$(mktemp -d)/aurora-cfg"

  if ! clone "$AURORA_CFG_URL" "$AURORA_CFG_TMP" master; then
    echo "::error::luci-app-aurora-config 拉取失败，包会被 defconfig 剔除"
    exit 1
  fi

  if [ ! -f "$AURORA_CFG_TMP/Makefile" ]; then
    echo "::error::$AURORA_CFG_TMP/Makefile 不存在，包无法被索引"
    exit 1
  fi
  rm -rf "$PKG_DIR/luci-app-aurora-config"
  mkdir -p "$PKG_DIR/luci-app-aurora-config"
  cp -r "$AURORA_CFG_TMP"/. "$PKG_DIR/luci-app-aurora-config/"
  rm -rf "$PKG_DIR/luci-app-aurora-config/.git"
  echo "✅ 已拷贝: luci-app-aurora-config"

  rm -rf "$AURORA_CFG_TMP"
fi

# =========================================================

# =========================================================
# PartExp —— sirpdboy/luci-app-partexp
# 单包仓库：根下 luci-app-partexp/ 就是包目录，直接拷。
# po 文件名 partexp.po 与 LUCI_BASENAME 对应，无需改名。
# =========================================================
if [ "$ADD_PARTEXP" = "true" ]; then
  PARTEXP_URL="https://github.com/sirpdboy/luci-app-partexp"
  PARTEXP_TMP="$(mktemp -d)/partexp"

  if ! clone "$PARTEXP_URL" "$PARTEXP_TMP" main; then
    echo "::error::luci-app-partexp 拉取失败，包会被 defconfig 剔除"
    exit 1
  fi

  if [ ! -f "$PARTEXP_TMP/luci-app-partexp/Makefile" ]; then
    echo "::error::$PARTEXP_TMP/luci-app-partexp/Makefile 不存在，包无法被索引"
    exit 1
  fi
  rm -rf "$PKG_DIR/luci-app-partexp"
  cp -r "$PARTEXP_TMP/luci-app-partexp" "$PKG_DIR/"
  echo "✅ 已拷贝: luci-app-partexp"

  rm -rf "$PARTEXP_TMP"
fi

# =========================================================

# =========================================================
# Dufs —— zouzonghao/luci-app-dufs
# 单包仓库：Makefile 就在仓库根目录，整个仓库（除 .git）就是包目录。
# 默认关闭（ADD_DUFS=false）；需要时把开关改 true 并在 config 里
# 把 "# CONFIG_PACKAGE_luci-app-dufs is not set" 改成 "=y"。
# =========================================================
if [ "$ADD_DUFS" = "true" ]; then
  DUFS_URL="https://github.com/zouzonghao/luci-app-dufs"
  DUFS_TMP="$(mktemp -d)/dufs"

  if ! clone "$DUFS_URL" "$DUFS_TMP" main; then
    echo "::error::luci-app-dufs 拉取失败，包会被 defconfig 剔除"
    exit 1
  fi

  if [ ! -f "$DUFS_TMP/Makefile" ]; then
    echo "::error::$DUFS_TMP/Makefile 不存在，包无法被索引"
    exit 1
  fi
  rm -rf "$PKG_DIR/luci-app-dufs"
  mkdir -p "$PKG_DIR/luci-app-dufs"
  cp -r "$DUFS_TMP"/. "$PKG_DIR/luci-app-dufs/"
  rm -rf "$PKG_DIR/luci-app-dufs/.git"
  echo "✅ 已拷贝: luci-app-dufs"

  rm -rf "$DUFS_TMP"
fi

# ---------------------------------------------------------
# 让新包进入索引（与 diy-part1.sh 相同的重建逻辑）
# 判据是 tmp/.packageinfo；注意删 stamp，否则 scan_unchanged 会跳过扫描
# ---------------------------------------------------------
if [ -n "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then
  rm -f tmp/.packageinfo tmp/.targetinfo
  rm -f tmp/info/.scan-packageinfo.stamp tmp/info/.scan-targetinfo.stamp
  rm -f tmp/.config-package.in tmp/.config-target.in

  echo ">>> make prepare-tmpinfo（重新扫描 package/ 树）"
  make -s prepare-tmpinfo OPENWRT_BUILD= 2>&1 | tail -5 || true

  echo "=========================================="
  echo "包索引校验（判据：tmp/.packageinfo）"
  echo "=========================================="
  INDEX_MISS=""
  for d in "$PKG_DIR"/*; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    [ -f "$d/Makefile" ] || { echo "  -  $n（无根 Makefile，跳过）"; continue; }
    if grep -qx "Package: $n" tmp/.packageinfo 2>/dev/null; then
      echo "  ✅ $n"
    else
      echo "  ❌ $n —— tmp/.packageinfo 里查不到"
      INDEX_MISS="$INDEX_MISS $n"
      for f in "logs/package/$n/dump.txt" "logs/package/custom/$n/dump.txt"; do
        [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; }
      done
    fi
  done

  # 必装插件（config 里是 =y 的）必须进索引，否则 defconfig 会静默剔除
  REQUIRED=""
  if [ "$ADD_NIKKI" = "true" ]; then
    REQUIRED="$REQUIRED luci-app-nikki nikki mihomo-meta"
  fi
  if [ "$ADD_EASYTIER" = "true" ]; then
    REQUIRED="$REQUIRED luci-app-easytier easytier easytier-noweb"
  fi
  if [ "$ADD_HARBOR" = "true" ]; then
    REQUIRED="$REQUIRED luci-app-harbor-file-pro"
  fi
  if [ "$ADD_AURORA" = "true" ]; then
    REQUIRED="$REQUIRED luci-theme-aurora luci-app-aurora-config"
  fi
  if [ "$ADD_PARTEXP" = "true" ]; then
    REQUIRED="$REQUIRED luci-app-partexp"
  fi
  if [ "$ADD_DUFS" = "true" ]; then
    REQUIRED="$REQUIRED luci-app-dufs"
  fi
  HARD_MISS=""
  for r in $REQUIRED; do
    grep -qx "Package: $r" tmp/.packageinfo 2>/dev/null || HARD_MISS="$HARD_MISS $r"
  done
  if [ -n "$HARD_MISS" ]; then
    echo "::error::以下必装插件未进入 tmp/.packageinfo，defconfig 会把 .config 里的 =y 静默剔除:$HARD_MISS"
    echo "  已索引缺失清单:$INDEX_MISS"
    exit 1
  fi
  [ -n "$INDEX_MISS" ] && echo "::warning::部分可选包未进入索引（不影响必装插件）:$INDEX_MISS"
else
  echo "未启用任何第二批插件"
fi

echo "🎉 diy-part3.sh 执行完毕"

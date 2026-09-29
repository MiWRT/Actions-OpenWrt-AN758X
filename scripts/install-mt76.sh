#!/usr/bin/env bash
# ==================================================================
# 安装 mt76 无线驱动包（AN7581 / AN7583 的 WiFi NPU 卸载版本）
#
#   install-mt76.sh <ponwrt 源码目录> <本仓库 mt76 目录> [strict]
#
# 做了什么：
#   把仓库里的 mt76/（Makefile + patches/）覆盖到源码树的
#   package/kernel/mt76/，让无线驱动带上两样东西：
#     1) Makefile 里为 an7581 / an7583 打开 CONFIG_MT76_NPU / CONFIG_MT7915_NPU
#     2) patches/113-mt7915-npu-vendor-rewrite.patch（NPU vendor 改写）
#
# 为什么不是"打补丁"而是"换包"：
#   mt76 的补丁由 OpenWrt 的 quilt 在解压源码后应用（package.mk 自动做），
#   所以只要把补丁放进 package/kernel/mt76/patches/ 就会生效；
#   而 Makefile 里那段 ifneq (...an7581...an7583...) 是包级开关，
#   只能靠替换 Makefile 加进去。两者一起换最省事。
#
# 安全设计：
#   - mt76/ 目录不存在或为空 → 跳过，不报错（等于用上游自带版本）
#   - 只覆盖我们提供的文件，不删除源码树里已有的其它文件
#   - 会对比覆盖前后的 PKG_SOURCE_VERSION，上游换了 mt76 源码版本时告警
#     （版本变了补丁可能贴不上，需要重新整理 patches/）
#   - 逐个校验补丁完整性（必须有 --- / +++ 头，不能是空文件）
#   - 列出源码树里残留的其它补丁，提示可能与新补丁冲突
#   - strict=true（默认）时，目标包缺失/没 Makefile/缺关键补丁会直接失败
#
# 环境变量：
#   MT76_REQUIRED_PATCHES  必选补丁清单（空格分隔），默认 100/110/113
#   MT76_VERIFY_ONLY=true  只校验不写文件（用于 dry-run / 事后复核）
#
# 用法：
#   bash scripts/install-mt76.sh /workdir/openwrt mt76 true
#   MT76_VERIFY_ONLY=true bash scripts/install-mt76.sh /workdir/openwrt mt76 false
# ==================================================================
set -uo pipefail

TARGET="${1:-}"
MDIR="${2:-}"
STRICT="${3:-true}"

# 必选补丁：113 是 NPU vendor 改写，缺了 WiFi 就走纯软件转发；
# 100 / 110 与 ponwrt 自带一致，缺了会改变 eeprom 行为（发射功率 / cal-free）
REQUIRED_PATCHES="${MT76_REQUIRED_PATCHES:- \
100-wifi-mt76-mt7996-Use-tx_power-from-default-fw-if-EEP.patch \
110-mt7915-add-mt7916-cal-free-merge.patch \
113-mt7915-npu-vendor-rewrite.patch}"
VERIFY_ONLY="${MT76_VERIFY_ONLY:-false}"

if [ -z "$TARGET" ] || [ -z "$MDIR" ]; then
  echo "::error::用法: install-mt76.sh <ponwrt 源码目录> <mt76 目录> [strict]"
  exit 1
fi

PKGDIR="$TARGET/package/kernel/mt76"

echo "========================================"
echo "安装 mt76 无线驱动包"
echo "  源:   $MDIR"
echo "  目标: $PKGDIR"
[ "$VERIFY_ONLY" = "true" ] && echo "  模式: 仅校验（不写文件）"
echo "========================================"

if [ ! -d "$MDIR" ] || [ -z "$(ls -A "$MDIR" 2>/dev/null)" ]; then
  echo ">>> mt76 目录不存在或为空，跳过（沿用 ponwrt 自带版本）"
  exit 0
fi

if [ ! -f "$MDIR/Makefile" ]; then
  echo "::error::mt76 目录里没有 Makefile: $MDIR"
  [ "$STRICT" = "true" ] && exit 1
  exit 0
fi

if [ ! -d "$PKGDIR" ]; then
  echo "::error::源码树里找不到 package/kernel/mt76，上游结构变了？"
  [ "$STRICT" = "true" ] && exit 1
  exit 0
fi

# ---- 记录覆盖前的 mt76 源码版本，用于判断上游是否换过版本 ----
ver_of() { grep -m1 '^PKG_SOURCE_VERSION:=' "$1" 2>/dev/null | sed 's/.*:=//'; }
OLD_VER="$(ver_of "$PKGDIR/Makefile")"
NEW_VER="$(ver_of "$MDIR/Makefile")"
echo "  mt76 源码版本: ${OLD_VER:-未知} -> ${NEW_VER:-未知}"

# ---- 补丁完整性校验（覆盖之前先自查，避免把坏补丁写进源码树）----
echo "  --- 补丁完整性校验 ---"
patch_ok=1
n_patch=0
for p in "$MDIR"/patches/*; do
  [ -f "$p" ] || continue
  name="$(basename "$p")"
  n_patch=$((n_patch + 1))
  if [ ! -s "$p" ]; then
    echo "::error::补丁为空文件: $name"
    patch_ok=0
  elif ! grep -qE '^(---|\+\+\+) ' "$p"; then
    echo "::error::补丁缺少 ---/+++ 头（不是标准 diff）: $name"
    patch_ok=0
  elif ! grep -q '^+++ ' "$p"; then
    echo "::error::补丁缺少 +++ 头: $name"
    patch_ok=0
  else
    echo "  ✅ $name ($(wc -l < "$p") 行)"
  fi
done
if [ "$patch_ok" -ne 1 ]; then
  echo "::error::mt76 补丁完整性校验失败，终止安装"
  [ "$STRICT" = "true" ] && exit 1
fi

mkdir -p "$MDIR/patches" 2>/dev/null
for want in $REQUIRED_PATCHES; do
  if [ ! -f "$MDIR/patches/$want" ]; then
    echo "::error::缺少必选补丁: $want"
    [ "$STRICT" = "true" ] && exit 1
  fi
done

# ---- 源码树里残留的补丁（仓库没提供的）----
# 只覆盖不删除，所以上游若留着同名不同内容的补丁会被我们盖掉；
# 不同名的会和新补丁一起被 quilt 应用，可能上下文冲突，这里列出来提醒
if [ -d "$PKGDIR/patches" ]; then
  echo "  --- 源码树原有补丁（不删除，仅提示）---"
  for old in "$PKGDIR"/patches/*; do
    [ -f "$old" ] || continue
    oldname="$(basename "$old")"
    if [ -f "$MDIR/patches/$oldname" ]; then
      if cmp -s "$old" "$MDIR/patches/$oldname"; then
        echo "  = $oldname（与仓库版本一致，将被覆盖）"
      else
        echo "::warning::$oldname 源码树版本与仓库版本不同，将被覆盖为仓库版本"
      fi
    else
      echo "::warning::$oldname 是源码树独有补丁，会随仓库补丁一起应用（可能冲突）"
    fi
  done
fi

if [ "$VERIFY_ONLY" = "true" ]; then
  echo ">>> VERIFY_ONLY=true，跳过写入"
else
  # ---- 覆盖：Makefile 直接替换，patches 逐个拷进去 ----
  cp -f "$MDIR/Makefile" "$PKGDIR/Makefile"
  echo "  ✅ Makefile 已替换"

  mkdir -p "$PKGDIR/patches"
  n=0
  for p in "$MDIR"/patches/*; do
    [ -f "$p" ] || continue
    cp -f "$p" "$PKGDIR/patches/$(basename "$p")"
    echo "  ✅ $(basename "$p")"
    n=$((n + 1))
  done
  echo "  补丁合计: $n 个"
fi

# ---- 校验：NPU 开关 + 关键补丁 + target 覆盖范围 ----
echo "  --- NPU 卸载校验 ---"
fail=0
MK="$MDIR/Makefile"
if [ "$VERIFY_ONLY" = "true" ] && [ -f "$PKGDIR/Makefile" ]; then
  MK="$PKGDIR/Makefile"
fi

if grep -q 'CONFIG_MT76_NPU' "$MK"; then
  echo "  ✅ Makefile 含 CONFIG_MT76_NPU 开关（NPU 卸载已开启）"
else
  echo "::error::mt76 Makefile 里没有 CONFIG_MT76_NPU，NPU 卸载不会生效"
  fail=1
fi

# 覆盖哪些 subtarget：AN7581 / AN7583 必须都在，否则对应机型 WiFi 不卸载
for t in an7581 an7583; do
  if grep -q "CONFIG_TARGET_airoha_${t}" "$MK"; then
    echo "  ✅ NPU 开关覆盖 ${t}"
  elif [ "$t" = "an7583" ]; then
    echo "::warning::Makefile 未覆盖 ${t}：AN7583 机型（nokia_xg-040g-mf*）的 WiFi 不会走 NPU 卸载"
  else
    echo "::error::Makefile 未覆盖 ${t}"
    fail=1
  fi
done

if [ -f "$MDIR/patches/113-mt7915-npu-vendor-rewrite.patch" ] || \
   [ -f "$PKGDIR/patches/113-mt7915-npu-vendor-rewrite.patch" ]; then
  echo "  ✅ NPU vendor 改写补丁就位（113）"
else
  echo "::warning::缺少 113-mt7915-npu-vendor-rewrite.patch（MT7915/MT7916 不会卸载到 NPU）"
  fail=1
fi

if [ -n "$OLD_VER" ] && [ -n "$NEW_VER" ] && [ "$OLD_VER" != "$NEW_VER" ]; then
  echo "::warning::mt76 源码版本变了（$OLD_VER -> $NEW_VER），补丁可能需要重新整理"
fi

# ---- 汇总（GitHub Actions 步骤摘要）----
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### mt76 / WiFi NPU 卸载"
    echo ""
    echo "| 项目 | 值 |"
    echo "|---|---|"
    echo "| mt76 源码版本 | \`${NEW_VER:-未知}\`（上游原 \`${OLD_VER:-未知}\`）|"
    echo "| 补丁数 | $n_patch |"
    echo "| CONFIG_MT76_NPU | $(grep -q 'CONFIG_MT76_NPU' "$MK" && echo '✅ 已开启' || echo '❌ 未开启') |"
    echo "| AN7581 覆盖 | $(grep -q 'CONFIG_TARGET_airoha_an7581' "$MK" && echo '✅' || echo '❌') |"
    echo "| AN7583 覆盖 | $(grep -q 'CONFIG_TARGET_airoha_an7583' "$MK" && echo '✅' || echo '❌') |"
    echo "| 113 NPU 补丁 | $([ -f "$MDIR/patches/113-mt7915-npu-vendor-rewrite.patch" ] || [ -f "$PKGDIR/patches/113-mt7915-npu-vendor-rewrite.patch" ] && echo '✅' || echo '❌') |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "----------------------------------------"
if [ "$fail" -ne 0 ] && [ "$STRICT" = "true" ]; then
  echo "::error::mt76 安装校验失败"
  exit 1
fi
echo "mt76 安装完成"
echo "----------------------------------------"
exit 0

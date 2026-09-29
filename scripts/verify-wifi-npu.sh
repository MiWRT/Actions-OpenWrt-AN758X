#!/usr/bin/env bash
# ==================================================================
# WiFi NPU 卸载 —— 编译前静态自检（在 make defconfig 之后跑）
#
#   bash scripts/verify-wifi-npu.sh [源码目录]
#
# 目的：mt76 的 NPU 补丁"复制进去了"≠"编出来会生效"。
#   补丁由 quilt 在解压源码后才应用、NPU 宏由 Makefile 按 subtarget 判断、
#   113 补丁的 Kconfig 还依赖内核 NET_AIROHA_NPU、DTS 要带保留内存区。
#   任何一环断了，编出来的 Wi-Fi 都悄悄退回纯软件转发，日志里几乎看不出来。
#   这里把四环都查一遍，在编译前把"没生效"变成一行可见的警告。
#
# 检查项：
#   1) mt76 包 Makefile 是否带 CONFIG_MT76_NPU，且覆盖当前 subtarget
#   2) 113 补丁是否在 package/kernel/mt76/patches/ 里
#   3) .config 里无线驱动（kmod-mt7915e / kmod-mt7996e）是否启用
#   4) 内核是否开 NPU 支持（NET_AIROHA_NPU）
#   5) NPU 固件是否有着落（stock 包 / files/ 覆盖）
#   6) 机型 DTS 是否已引入 NPU WiFi 保留内存区
#
# 全部为「提示级」：只打 warning，不阻断构建
#   （避免把可选组合当成硬错误；真正致命的校验在 install-mt76.sh 里做）
# ==================================================================
set -uo pipefail

SRC="${1:-.}"
SOC="${SOC:-}"
PROFILE="${PROFILE:-}"
NPU_FW="${NPU_FW:-stock}"
NPU_WLAN_MEM="${NPU_WLAN_MEM:-true}"

cd "$SRC" 2>/dev/null || { echo "::error::源码目录不存在: $SRC"; exit 1; }

MT76_DIR="package/kernel/mt76"
SUMMARY="${GITHUB_STEP_SUMMARY:-}"
warn=0
rows=()

note()  { echo "$@"; }
row()   { rows+=("| $1 | $2 |"); }
warnx() { echo "::warning::$1"; warn=$((warn + 1)); }

echo "========================================"
echo "WiFi NPU 卸载自检（编译前）"
echo "  源码: $PWD / SoC=${SOC:-自动} / profile=${PROFILE:-未指定}"
echo "========================================"

# ------------------------------------------------------------------
# 0) 基本信息：target / subtarget
# ------------------------------------------------------------------
SUB=""
[ -f .config ] && SUB="$(grep -m1 '^CONFIG_TARGET_SUBTARGET=' .config | cut -d'"' -f2)"
[ -z "$SUB" ] && SUB="$SOC"
[ -z "$SUB" ] && SUB="an7581"
note "  subtarget: ${SUB}"

# ------------------------------------------------------------------
# 1) mt76 Makefile 的 NPU 开关 + 是否覆盖当前 subtarget
# ------------------------------------------------------------------
MK="$MT76_DIR/Makefile"
if [ ! -f "$MK" ]; then
  warnx "找不到 $MK，无法确认 NPU 卸载（mt76=upstream 或源码结构变了）"
  row "mt76 NPU 宏" "❌ 无 Makefile"
else
  if grep -q 'CONFIG_MT76_NPU' "$MK"; then
    note "  ✅ mt76 Makefile 含 CONFIG_MT76_NPU"
    row "mt76 CONFIG_MT76_NPU" "✅"
  else
    warnx "mt76 Makefile 没有 CONFIG_MT76_NPU —— Wi-Fi 将走纯软件转发（检查 mt76 输入项是不是选了 upstream）"
    row "mt76 CONFIG_MT76_NPU" "❌"
  fi

  if grep -q "CONFIG_TARGET_airoha_${SUB}" "$MK"; then
    note "  ✅ NPU 开关覆盖当前 subtarget: ${SUB}"
    row "NPU 覆盖 ${SUB}" "✅"
  else
    warnx "mt76 的 NPU 开关未覆盖 CONFIG_TARGET_airoha_${SUB} —— 本机型 Wi-Fi 不会卸载到 NPU"
    row "NPU 覆盖 ${SUB}" "❌"
  fi

  # MT7916 / MT7915 走 mt7915 驱动，MT799x 走 mt7996 驱动
  if grep -q 'CONFIG_MT7915_NPU' "$MK"; then
    note "  ✅ CONFIG_MT7915_NPU（MT7915/MT7916）"
  fi
  if grep -q 'CONFIG_MT7996_NPU' "$MK"; then
    note "  ✅ CONFIG_MT7996_NPU（MT7992/MT7996）"
  fi
fi

# ------------------------------------------------------------------
# 2) 113 补丁是否就位
# ------------------------------------------------------------------
if [ -f "$MT76_DIR/patches/113-mt7915-npu-vendor-rewrite.patch" ]; then
  note "  ✅ 113-mt7915-npu-vendor-rewrite.patch 已就位（quilt 解压后应用）"
  row "113 NPU vendor 补丁" "✅ 已就位"
else
  warnx "缺少 $MT76_DIR/patches/113-mt7915-npu-vendor-rewrite.patch —— mt7915/7916 无 NPU 改写"
  row "113 NPU vendor 补丁" "❌ 缺失"
fi
note "  mt76 patches 目录:"
ls -1 "$MT76_DIR/patches/" 2>/dev/null | sed 's/^/    - /' || echo "    (无)"

# ------------------------------------------------------------------
# 3) 无线驱动包是否启用
# ------------------------------------------------------------------
if [ ! -f .config ]; then
  warnx "没有 .config，跳过配置检查"
else
  for p in kmod-mt7915e kmod-mt7996e; do
    if grep -q "^CONFIG_PACKAGE_${p}=[ym]" .config; then
      note "  ✅ CONFIG_PACKAGE_${p} 已启用"
      row "${p}" "✅"
    else
      note "  · ${p} 未启用（该机型可能不是这个 Wi-Fi 芯片）"
      row "${p}" "— 未启用"
    fi
  done

  # ----------------------------------------------------------------
  # 4) 内核 NPU 支持（113 补丁 Kconfig: MT7915_NPU depends on NET_AIROHA_NPU）
  # ----------------------------------------------------------------
  KNPU=""
  for f in .config target/linux/airoha/config-*; do
    [ -f "$f" ] || continue
    if grep -qE '^CONFIG_(KERNEL_)?NET_AIROHA_NPU=[ym]' "$f"; then
      KNPU="$f"
      break
    fi
  done
  if [ -n "$KNPU" ]; then
    note "  ✅ 内核 NPU 支持已开（NET_AIROHA_NPU，来自 $KNPU）"
    row "内核 NET_AIROHA_NPU" "✅"
  else
    warnx "未在任何 config 里找到 NET_AIROHA_NPU —— 113 补丁的 Kconfig depends 不满足，NPU 路径可能被静默关掉；确认内核是否自带该符号"
    row "内核 NET_AIROHA_NPU" "⚠ 未找到"
  fi

  # ----------------------------------------------------------------
  # 5) NPU 固件有着落
  # ----------------------------------------------------------------
  if [ "$NPU_FW" = "clanker" ]; then
    if [ -d files/lib/firmware/airoha ] && \
       [ "$(ls files/lib/firmware/airoha/*_npu_*.bin 2>/dev/null | wc -l)" -ge 2 ]; then
      note "  ✅ ClankerNPU 镜像已在 files/lib/firmware/airoha/"
      row "NPU 固件 (clanker)" "✅ files/ 覆盖"
    else
      warnx "npu_fw=clanker 但 files/lib/firmware/airoha/ 下镜像不足 —— NPU 起不来"
      row "NPU 固件 (clanker)" "❌ 镜像缺失"
    fi
  else
    if grep -qE '^CONFIG_PACKAGE_airoha-(en7581|en7581-mt7996|an7583)-npu-firmware=[ym]' .config; then
      note "  ✅ stock NPU 固件包已启用"
      row "NPU 固件 (stock)" "✅"
    else
      warnx "stock NPU 固件包未启用且 npu_fw≠clanker —— NPU 不会起来（Wi-Fi/有线都退回软件转发）"
      row "NPU 固件" "⚠ 无固件"
    fi
  fi
fi

# ------------------------------------------------------------------
# 6) DTS 保留内存区
# ------------------------------------------------------------------
DTS_DIR="target/linux/airoha/dts"
if [ "$NPU_WLAN_MEM" != "true" ]; then
  note "  · npu_wlan_mem=false，跳过 DTS 内存区检查"
  row "DTS 保留内存区" "— 已关闭"
elif [ ! -d "$DTS_DIR" ]; then
  warnx "找不到 $DTS_DIR，跳过 DTS 检查"
  row "DTS 保留内存区" "⚠ 目录缺失"
else
  HIT="$(grep -rl 'npu-wlan\|npu-clanker' "$DTS_DIR" 2>/dev/null | head -3 | tr '\n' ' ')"
  if [ -n "$HIT" ]; then
    note "  ✅ DTS 已引入 NPU WiFi 内存区: $HIT"
    row "DTS 保留内存区" "✅"
  else
    warnx "DTS 里没有 npu-wlan / npu-clanker include —— airoha_npu_wlan_init_memory() 会找不到 pkt/tx-pkt/tx-bufid/ba，Wi-Fi 卸载初始化失败"
    row "DTS 保留内存区" "❌ 未引入"
  fi
fi

# ------------------------------------------------------------------
# 汇总
# ------------------------------------------------------------------
echo "----------------------------------------"
if [ "$warn" -eq 0 ]; then
  echo "✅ WiFi NPU 卸载链路自检通过（补丁、宏、驱动、固件、内存区都在）"
else
  echo "⚠ 自检发现 $warn 处待确认（详见上方 ::warning:: 行）"
fi
echo "提示：补丁真正应用发生在 quilt 解压 mt76 源码之后，"
echo "      编译日志里搜 'Applying patches to mt76' / '113-mt7915' 可确认。"
echo "----------------------------------------"

if [ -n "$SUMMARY" ]; then
  {
    echo "### WiFi NPU 卸载自检"
    echo ""
    echo "| 检查项 | 结果 |"
    echo "|---|---|"
    printf '%s\n' "${rows[@]}"
    echo ""
    echo "警告数: $warn"
  } >> "$SUMMARY"
fi

exit 0

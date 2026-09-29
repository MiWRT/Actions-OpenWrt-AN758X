#!/usr/bin/env bash
# ==================================================================
# 给机型 DTS 补 NPU 节点内容（在 ponwrt 源码根目录执行）
#
# 做两件事，都由调用方用环境变量控制：
#   1. 引入 WiFi 卸载必需的保留内存区（pkt / tx-pkt / tx-bufid / ba）
#      airoha_npu 驱动的 airoha_npu_wlan_init_memory() 按名字查这几块，
#      缺一个 WiFi 卸载初始化就失败；只做有线 PPE/HWNAT 卸载不需要。
#   2. 当固件名不是驱动默认名时，写 firmware-name 属性（rv32 在前、data 在后）
#
#   ADD_WLAN_MEM=false|true    是否补内存区（默认 true）
#   SOC      an7581|an7583     （默认 an7581）
#   PROFILE  机型 profile       （用于挑要改哪个 dts / dtsi）
#   WIFI     MT7916|...         （NOWIFI 时跳过）
#   FW_PREFIX                  固件名前缀，非默认才写 firmware-name
#   PONWRT_DIR                 源码根目录，默认 .
#
# 健壮性（相比初版的改动）：
#   - 生成 <soc>-npu-clanker.dtsi 之前先确认源码树里真的有
#     <soc>-npu-wlan.dtsi。没有就只写 firmware-name、不写 include，
#     否则 DTS 编译阶段会直接报 "file not found" 而整轮编译白跑。
#   - 不再硬性只对 an7581 生效：源码树里存在 an7583-npu-wlan.dtsi 时
#     同样处理（原来 an7583 机型一律跳过且无补救）。
#   - 机型 dts 定位支持自动探测：登记映射未命中时，按
#     「profile 原样 / 下划线转连字符」×「.dts / .dtsi」四个候选找，
#     找不到就把 dts 目录里同关键字的文件列出来，方便补进映射表。
# ==================================================================
set -euo pipefail

PONWRT_DIR="${PONWRT_DIR:-.}"
SOC="${SOC:-an7581}"
PROFILE="${PROFILE:-}"
WIFI="${WIFI:-MT7916}"
ADD_WLAN_MEM="${ADD_WLAN_MEM:-true}"
FW_PREFIX="${FW_PREFIX:-}"

case "$(echo "$SOC" | tr 'a-z' 'A-Z')" in
  AN7581) DEF_PREFIX="en7581"; SOC_LC="an7581" ;;
  AN7583) DEF_PREFIX="an7583"; SOC_LC="an7583" ;;
  *)      DEF_PREFIX="$SOC";   SOC_LC="$SOC" ;;
esac
FW_PREFIX="${FW_PREFIX:-$DEF_PREFIX}"

DTS_DIR="$PONWRT_DIR/target/linux/airoha/dts"
[ -d "$DTS_DIR" ] || { echo "::error::找不到 $DTS_DIR，检查 PONWRT_DIR"; exit 1; }

if [ "$ADD_WLAN_MEM" != "true" ]; then
  echo ">>> ADD_WLAN_MEM=false，跳过 DTS 修改"
  exit 0
fi

if [ "$WIFI" = "NOWIFI" ]; then
  echo ">>> WIFI=NOWIFI，不需要 WiFi 卸载内存区，跳过"
  exit 0
fi

# ------------------------------------------------------------------
# 0) 确认源码树里有这份 SoC 的 NPU WiFi 内存区 dtsi
#    没有就别 include —— 否则设备树编译直接失败
# ------------------------------------------------------------------
WLAN_DTSI="${SOC_LC}-npu-wlan.dtsi"
CLANKER_DTSI="${SOC_LC}-npu-clanker.dtsi"
HAVE_WLAN=1
if [ ! -f "$DTS_DIR/$WLAN_DTSI" ]; then
  HAVE_WLAN=0
  echo "::warning::源码树里没有 $DTS_DIR/$WLAN_DTSI"
  echo "::warning::$SOC_LC 的 WiFi 卸载保留内存区无法补上（只写 firmware-name）"
  echo "::warning::若该机型确实需要，请参照 an7581-npu-wlan.dtsi 自行补一份并放进 patches/ponwrt/"
fi

# ------------------------------------------------------------------
# 机型 -> 要改的 dts / dtsi
#   MT7916 机型（烽火 HG5585F-CT/CU、兆能 ZN515XG-D、ZN504XG-D）共用
#   一份 common.dtsi，改一处即可覆盖 CT/CU 与 ZN50x 两个机型。
# ------------------------------------------------------------------
case "$PROFILE" in
  fiberhome_hg5585f-ct|fiberhome_hg5585f-cu) TARGETS="an7581-fiberhome-hg5585f-common.dtsi" ;;
  znxt_zn515xg-d|znxt_zn504xg-d)             TARGETS="an7581-znxt-zn50xg-d-common.dtsi" ;;
  fiberhome_hg5382a)                          TARGETS="an7581-fiberhome-hg5382a.dts" ;;
  gemtek_xg2010g)                             TARGETS="an7581-gemtek-xg2010g.dts" ;;
  unionman_ung00a)                            TARGETS="an7581-unionman-ung00a.dts" ;;
  nokia_xg-040g-md-ubi)                       TARGETS="an7581-nokia_xg-040g-md-common.dtsi" ;;
  nokia_xg-040g-tf-ubi)                       TARGETS="an7581-nokia_xg-040g-tf-common.dtsi" ;;
  h3c_hm2004-du)                              TARGETS="an7581-h3c-hm2004-du.dts" ;;
  all|"")
    TARGETS=""
    echo "::warning::profile=${PROFILE:-空} 无法直接定位 DTS，尝试自动探测" ;;
  *) TARGETS="${SOC_LC}-${PROFILE}.dts" ;;
esac

# ------------------------------------------------------------------
# 自动探测：登记映射没写、或写了但文件不存在时的兜底
#   profile 用下划线（nokia_xg-040g-mf），dts 里可能用连字符，两种都试
# ------------------------------------------------------------------
resolve_dts() {
  local dash="${PROFILE//_/-}"
  local base="${dash%-ubi}"    # nokia_xg-040g-md-ubi -> nokia-xg-040g-md（去掉 ubi 后缀）
  local cand
  for cand in \
    "${SOC_LC}-${PROFILE}.dts"       "${SOC_LC}-${PROFILE}.dtsi" \
    "${SOC_LC}-${dash}.dts"          "${SOC_LC}-${dash}.dtsi" \
    "${SOC_LC}-${dash}-common.dts"   "${SOC_LC}-${dash}-common.dtsi" \
    "${SOC_LC}-${base}-common.dts"   "${SOC_LC}-${base}-common.dtsi" \
    "${SOC_LC}-${PROFILE}-common.dts" "${SOC_LC}-${PROFILE}-common.dtsi"; do
    [ -n "$PROFILE" ] || continue
    [ -f "$DTS_DIR/$cand" ] && { echo "$cand"; return 0; }
  done
  return 1
}

if [ -z "${TARGETS:-}" ] || [ ! -f "$DTS_DIR/${TARGETS%% *}" ]; then
  if [ -n "${TARGETS:-}" ]; then
    echo "::warning::映射表里登记的 $TARGETS 在源码树里不存在，尝试自动探测"
  fi
  if FOUND="$(resolve_dts)"; then
    echo ">>> 自动探测到机型 DTS: $FOUND"
    TARGETS="$FOUND"
  else
    echo "::warning::未能定位 ${PROFILE:-未知机型} 的 DTS，跳过内存区补充"
    if [ -n "$PROFILE" ]; then
      echo "  候选（dts 目录里带关键字的文件，可补进本脚本的映射表）："
      ls -1 "$DTS_DIR" 2>/dev/null | grep -i -- "${PROFILE%%_*}" | sed 's/^/    - /' || echo "    (无)"
    fi
    TARGETS=""
  fi
fi

# ------------------------------------------------------------------
# 生成 dtsi
# ------------------------------------------------------------------
{
  echo '// SPDX-License-Identifier: (GPL-2.0-only OR BSD-2-Clause)'
  echo '/* 由 apply-npu-dts.sh 生成：NPU WiFi 卸载保留内存区 + 可选固件名 */'
  echo ''
  if [ "$HAVE_WLAN" = "1" ]; then
    echo "#include \"$WLAN_DTSI\""
  else
    echo "/* 源码树缺少 $WLAN_DTSI，未引入内存区（避免 DTS 编译失败）*/"
  fi
  echo ''
  if [ "$FW_PREFIX" != "$DEF_PREFIX" ]; then
    echo '&npu {'
    echo "	firmware-name = \"airoha/${FW_PREFIX}_npu_rv32.bin\","
    echo "			\"airoha/${FW_PREFIX}_npu_data.bin\";"
    echo '};'
  else
    echo "/* FW_PREFIX=$FW_PREFIX 即驱动默认名，无需 firmware-name */"
  fi
} > "$DTS_DIR/$CLANKER_DTSI"
echo ">>> 生成 $DTS_DIR/$CLANKER_DTSI"
sed -n '1,20p' "$DTS_DIR/$CLANKER_DTSI"

# ------------------------------------------------------------------
# 插进机型 dts（放在 #include "<soc>.dtsi" 之后）
# ------------------------------------------------------------------
if [ -z "$TARGETS" ]; then
  echo "::warning::没有任何机型 DTS 引入 $CLANKER_DTSI —— 本次 WiFi 卸载内存区未生效"
  echo "::warning::解决：把该机型的 dts 名补进本脚本的 PROFILE 映射表，或自行在 DTS 里 #include \"$CLANKER_DTSI\""
  exit 0
fi

ANCHOR="#include \"${SOC_LC}.dtsi\""
for t in $TARGETS; do
  f="$DTS_DIR/$t"
  if [ ! -f "$f" ]; then
    echo "::warning::DTS 不存在，跳过: $f"
    continue
  fi
  if grep -q "$CLANKER_DTSI" "$f"; then
    echo ">>> 已包含，跳过: $t"
    continue
  fi
  if grep -qF "$ANCHOR" "$f"; then
    sed -i "s|#include \"${SOC_LC}\.dtsi\"|#include \"${SOC_LC}.dtsi\"\n#include \"${CLANKER_DTSI}\"|" "$f"
    echo "✅ 已给 $t 加上 $CLANKER_DTSI"
  else
    echo "::warning::$t 里没找到 $ANCHOR，请手动插入 #include \"$CLANKER_DTSI\""
  fi
done

#!/usr/bin/env bash
# ==================================================================
# 把随仓库入库的 H3C 原厂 NPU 镜像包装成「可选插件包」—— 与
# gen-npu-fw-package.sh 完全同构，只是镜像不是现编的，而是原厂 /userfs 里
# 取出来的那份：
#
#   packages/npu-h3c-stock/npu_rv32.bin   (90644 B)  e2551187...
#   packages/npu-h3c-stock/npu_data.bin   ( 2764 B)  18849de1...
#
# 产物同样是标准 OpenWrt 包，用 CONFIG_PACKAGE_<name>=y 勾选：
#
#     CONFIG_PACKAGE_airoha-en7581-mt7916-h3c-npu-firmware=y
#
# 与原厂的两点差异（写在包描述里，选之前必须知道）：
#   1) 原厂 rv32 只有 ~90KB，ClankerNPU 现编的约 2MB —— 原厂跑的是配
#      MT7916 的裁剪版固件，不支持专用 NPU ring / HW-RRO / TX 数据面
#      （固件里对应 mailbox wrapper 直接打 "not support on 791X"），
#      下行走 TDMA 快转。
#   2) 原厂镜像本名就是 npu_rv32.bin / npu_data.bin，安装时按驱动默认前缀
#      （AN7581: en7581）改名落盘，所以不用改 DTS 的 firmware-name。
#
# 用法（全部走环境变量）：
#   SOC=AN7581 WIFI=MT7916 ./scripts/gen-npu-h3c-package.sh
#
# 环境变量：
#   SOC          AN7552 / AN7581 / AN7583            （默认 AN7581）
#   WIFI         变体名（仅用于包名与包描述，原厂镜像本身不区分变体）
#   FW_PREFIX    固件落盘前缀（空 = 驱动默认 en7581 / an7583）
#   WORK         工作目录，默认 ./.clanker-build（与 clanker 流程共用）
#   PKG_OUT_DIR  包输出目录，默认 ./package/custom
#   PONWRT_DIR   ponwrt 源码根目录，默认 .
#   SKIP_MD5     1 = 跳过 md5 校验（换了自己的镜像时用）
# ==================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SOC="$(echo "${SOC:-AN7581}" | tr 'a-z' 'A-Z')"
WIFI="$(echo "${WIFI:-MT7916}" | tr 'a-z' 'A-Z')"
FW_PREFIX="${FW_PREFIX:-}"

WORK="${WORK:-$REPO_DIR/.clanker-build}"
PKG_OUT_DIR="${PKG_OUT_DIR:-./package/custom}"
PONWRT_DIR="${PONWRT_DIR:-.}"
SKIP_MD5="${SKIP_MD5:-0}"

STOCK_DIR="$REPO_DIR/packages/npu-h3c-stock"
TEMPLATE="$STOCK_DIR/Makefile.in"

# linux-firmware 已占用的包名 + clanker 会生成的包名，都不能重名
RESERVED="airoha-en7581-npu-firmware airoha-en7581-mt7996-npu-firmware airoha-an7583-npu-firmware"

case "$SOC" in
  AN7581) DEF_PREFIX="en7581"; SOC_PKG="en7581" ;;
  AN7583) DEF_PREFIX="an7583"; SOC_PKG="an7583" ;;
  AN7552) DEF_PREFIX="en7581"; SOC_PKG="an7552" ;;
  *) echo "::error::未知 SoC: $SOC（支持 AN7552 / AN7581 / AN7583）"; exit 1 ;;
esac

PREFIX="${FW_PREFIX:-$DEF_PREFIX}"

# ------------------------------------------------------------------
# 1) 校验入库镜像（防止 .gitattributes 缺失 / core.autocrlf 把 bin 改坏）
# ------------------------------------------------------------------
RV32_SRC="$STOCK_DIR/npu_rv32.bin"
DATA_SRC="$STOCK_DIR/npu_data.bin"
for f in "$RV32_SRC" "$DATA_SRC"; do
  [ -s "$f" ] || { echo "::error::缺原厂镜像 $f"; exit 1; }
done

RV32_MD5="$(md5sum "$RV32_SRC" | awk '{print $1}')"
DATA_MD5="$(md5sum "$DATA_SRC" | awk '{print $1}')"
RV32_SIZE="$(stat -c%s "$RV32_SRC")"
DATA_SIZE="$(stat -c%s "$DATA_SRC")"

if [ "$SKIP_MD5" != "1" ]; then
  [ "$RV32_MD5" = "e2551187360799dadaea241f4973d80a" ] || {
    echo "::error::npu_rv32.bin md5 不符（$RV32_MD5），镜像可能被换行符转换污染"
    exit 1
  }
  [ "$DATA_MD5" = "18849de11feb56c008742fcb50576ecf" ] || {
    echo "::error::npu_data.bin md5 不符（$DATA_MD5），镜像可能被换行符转换污染"
    exit 1
  }
fi
echo "✅ 原厂镜像校验通过: rv32 ${RV32_SIZE}B / data ${DATA_SIZE}B"

[ -f "$TEMPLATE" ] || { echo "::error::找不到包模板 $TEMPLATE"; exit 1; }
mkdir -p "$WORK" "$PKG_OUT_DIR"

# ------------------------------------------------------------------
# 2) 生成包目录
# ------------------------------------------------------------------
NAME="airoha-${SOC_PKG}-$(echo "$WIFI" | tr 'A-Z' 'a-z')-h3c-npu-firmware"
for r in $RESERVED; do
  if [ "$NAME" = "$r" ]; then
    echo "::error::包名 $NAME 与 linux-firmware 官方包重名"
    exit 1
  fi
done

PKG_DIR="$PKG_OUT_DIR/$NAME"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/src"
cp "$RV32_SRC" "$PKG_DIR/src/${PREFIX}_npu_rv32.bin"
cp "$DATA_SRC" "$PKG_DIR/src/${PREFIX}_npu_data.bin"

# 冲突项：stock 三个 + clanker 同名变体（它们装的是同一批文件名）
CONFLICTS=""
for r in $RESERVED; do CONFLICTS="${CONFLICTS}	${r}\n"; done
CONFLICTS="${CONFLICTS}	airoha-${SOC_PKG}-$(echo "$WIFI" | tr 'A-Z' 'a-z')-npu-firmware\n"
CONFLICTS="${CONFLICTS}	airoha-${SOC_PKG}-$(echo "$WIFI" | tr 'A-Z' 'a-z')-clanker-npu-firmware\n"

sed \
  -e "s|@PKG_NAME@|$NAME|g" \
  -e "s|@PKG_VERSION@|1.0|g" \
  -e "s|@SOC@|$SOC|g" \
  -e "s|@WIFI@|$WIFI|g" \
  -e "s|@FW_PREFIX@|$PREFIX|g" \
  -e "s|@TITLE@|Airoha ${SOC} NPU firmware (${WIFI}, H3C stock image)|g" \
  "$TEMPLATE" > "$PKG_DIR/Makefile.tmpl"
awk -v c="$(printf "$CONFLICTS")" '{ if ($0 == "@CONFLICTS@") printf "%s\n", c; else print }' \
  "$PKG_DIR/Makefile.tmpl" > "$PKG_DIR/Makefile"
rm -f "$PKG_DIR/Makefile.tmpl"

echo "✅ 生成可选包: $PKG_DIR"
echo "   -> CONFIG_PACKAGE_${NAME}=y"
echo "   -> src/${PREFIX}_npu_rv32.bin (${RV32_SIZE} bytes)"
echo "   -> src/${PREFIX}_npu_data.bin (${DATA_SIZE} bytes)"

# ------------------------------------------------------------------
# 3) 写元信息（复用 clanker 流程的清单格式，Select 步骤无需区分来源）
# ------------------------------------------------------------------
printf '%s|%s|%s|%s|%s|%s|%s\n' \
  "$NAME" "$SOC" "$WIFI" "$PREFIX" "h3c-stock" "$RV32_SIZE" "$DATA_SIZE" \
  > "$WORK/npu-fw-packages.txt"

cat > "$WORK/npu-h3c.env" <<EOF
NPU_SOC=$SOC
NPU_WIFI=$WIFI
NPU_FW_SOURCE=h3c
NPU_FW_PREFIX=$PREFIX
NPU_PKG=$NAME
NPU_PKG_DIR=$PKG_OUT_DIR/$NAME
NPU_RV32_SIZE=$RV32_SIZE
NPU_DATA_SIZE=$DATA_SIZE
NPU_RV32_MD5=$RV32_MD5
NPU_DATA_MD5=$DATA_MD5
EOF

echo "=================================================="
echo "H3C 原厂 NPU 固件包清单（$WORK/npu-fw-packages.txt）:"
cat "$WORK/npu-fw-packages.txt"
echo "--------------------------------------------------"
echo "默认勾选: CONFIG_PACKAGE_${NAME}=y"
echo "=================================================="

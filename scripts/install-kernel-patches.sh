#!/usr/bin/env bash
# ==================================================================
# 把 patches/kernel/ 下的补丁放进 target/linux/airoha/patches-<ver>/
# 由 OpenWrt 自己的 quilt 流程在编译内核前统一应用。
#
#   install-kernel-patches.sh <源码根目录> <补丁目录>
#
# 跟 patches/ponwrt/ 的区别：
#   - ponwrt/   → 直接 git apply 打到源码树，立刻生效
#   - kernel/   → 只是复制文件，真正的打补丁发生在 kernel prepare 阶段
#                 （这时内核源码才解压好），所以必须走这个目录
#
# 命名建议：用 9xx- 前缀（如 950-my-fix.patch），保证排在官方补丁之后应用，
# 否则可能被官方补丁覆盖或产生冲突。
# ==================================================================
set -uo pipefail

SRC="${1:-.}"
PDIR="${2:-${SRC}/patches/kernel}"

if [ ! -d "$PDIR" ]; then
  echo ">>> [kernel] 补丁目录不存在，跳过: $PDIR"
  exit 0
fi

mapfile -t PATCHES < <(find "$PDIR" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) | sort)
if [ "${#PATCHES[@]}" -eq 0 ]; then
  echo ">>> [kernel] 补丁目录为空，跳过: $PDIR"
  exit 0
fi

# 自动探测内核补丁目录：优先匹配源码实际使用的版本
KDST=""
for d in "$SRC"/target/linux/airoha/patches-*; do
  [ -d "$d" ] || continue
  KDST="$d"
done

if [ -z "$KDST" ]; then
  echo "::error::[kernel] 未找到 target/linux/airoha/patches-* 目录，无法安装内核补丁"
  exit 1
fi

echo "========================================"
echo "安装内核补丁: ${#PATCHES[@]} 个 -> ${KDST#$SRC/}"
echo "========================================"

n=0
for p in "${PATCHES[@]}"; do
  name="$(basename "$p")"
  cp "$p" "$KDST/$name"
  echo "  ✅ $name"
  n=$((n + 1))
done

# 提醒命名顺序问题：不带数字前缀的补丁会按字母序混在官方补丁里
for p in "${PATCHES[@]}"; do
  name="$(basename "$p")"
  case "$name" in
    [0-9][0-9][0-9]-*) : ;;
    *) echo "::warning::[kernel] $name 没有数字前缀，应用顺序不确定；建议改名 9xx-$name" ;;
  esac
done

echo "----------------------------------------"
echo "[kernel] 已安装 $n 个补丁（由 quilt 在编译内核前应用）"
echo "----------------------------------------"

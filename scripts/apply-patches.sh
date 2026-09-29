#!/usr/bin/env bash
# ==================================================================
# 通用补丁应用脚本
#
#   apply-patches.sh <目标源码目录> <补丁目录> [说明标签]
#
# 行为：
#   - 补丁目录不存在 / 为空 → 直接跳过，不报错
#   - 只处理 *.patch 和 *.diff，按文件名字母序应用（用数字前缀控制顺序）
#   - 已应用过的补丁会被检测出来并跳过（幂等，重跑 CI 不会重复打）
#   - 先试 git apply -p1 --3way（能容忍上下文偏移），失败再试 patch -p1
#   - 单个补丁失败的处理由 PATCH_STRICT 决定：
#       PATCH_STRICT=true（默认）→ 立即报错退出，避免带着半成品继续编
#       PATCH_STRICT=false        → 只 warning，继续下一个
#
# 用法：
#   bash scripts/apply-patches.sh /workdir/openwrt patches/ponwrt "ponwrt"
#   PATCH_STRICT=false bash scripts/apply-patches.sh ./src patches/clanker "clanker"
# ==================================================================
set -uo pipefail

TARGET="${1:-}"
PDIR="${2:-}"
LABEL="${3:-$(basename "${2:-patches}")}"
PATCH_STRICT="${PATCH_STRICT:-true}"

if [ -z "$TARGET" ] || [ -z "$PDIR" ]; then
  echo "::error::用法: apply-patches.sh <目标源码目录> <补丁目录> [标签]"
  exit 1
fi

if [ ! -d "$TARGET" ]; then
  echo "::error::[$LABEL] 目标目录不存在: $TARGET"
  exit 1
fi

if [ ! -d "$PDIR" ]; then
  echo ">>> [$LABEL] 补丁目录不存在，跳过: $PDIR"
  exit 0
fi

# 只收 .patch / .diff，按名字排序（用 001- / 010- 这类数字前缀控制顺序）
mapfile -t PATCHES < <(find "$PDIR" -maxdepth 1 -type f \( -name '*.patch' -o -name '*.diff' \) | sort)
if [ "${#PATCHES[@]}" -eq 0 ]; then
  echo ">>> [$LABEL] 补丁目录为空，跳过: $PDIR"
  exit 0
fi

echo "========================================"
echo "应用补丁 [$LABEL]: ${#PATCHES[@]} 个 -> $TARGET"
echo "========================================"

IS_GIT="no"
git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 && IS_GIT="yes"

ok=0; skipped=0; failed=0

# 判断补丁是否已应用：反向 apply 能成功说明已经打过了
already_applied() {
  local p="$1"
  if [ "$IS_GIT" = "yes" ]; then
    git -C "$TARGET" apply -p1 --check --reverse "$p" >/dev/null 2>&1 && return 0
  fi
  patch -p1 --dry-run --reverse --forward -d "$TARGET" < "$p" >/dev/null 2>&1 && return 0
  return 1
}

try_apply() {
  local p="$1"
  if [ "$IS_GIT" = "yes" ] && git -C "$TARGET" apply -p1 --3way "$p" >/dev/null 2>&1; then
    return 0
  fi
  patch -p1 --forward -d "$TARGET" < "$p" >/dev/null 2>&1 && return 0
  return 1
}

for p in "${PATCHES[@]}"; do
  name="$(basename "$p")"
  if already_applied "$p"; then
    echo "  ⏭  已应用，跳过: $name"
    skipped=$((skipped + 1))
    continue
  fi
  if try_apply "$p"; then
    echo "  ✅ $name"
    ok=$((ok + 1))
  else
    echo "  ❌ $name"
    echo "     --- 诊断（git apply 详细输出）---"
    if [ "$IS_GIT" = "yes" ]; then
      git -C "$TARGET" apply -p1 --3way --verbose "$p" 2>&1 | head -20 || true
    fi
    echo "     检查项："
    echo "       1) 补丁路径前缀是否为 -p1（a/xxx → xxx）"
    echo "       2) 上游是否改过这些文件，需要重新生成补丁"
    echo "       3) 补丁是否放错了目录（ponwrt / kernel / clanker 三选一）"
    failed=$((failed + 1))
    if [ "$PATCH_STRICT" = "true" ]; then
      echo "::error::[$LABEL] 补丁应用失败: $name（设 PATCH_STRICT=false 可改为仅警告）"
      exit 1
    fi
  fi
done

echo "----------------------------------------"
echo "[$LABEL] 成功 $ok / 跳过 $skipped / 失败 $failed"
echo "----------------------------------------"

if [ "$failed" -gt 0 ] && [ "$PATCH_STRICT" = "true" ]; then
  exit 1
fi
exit 0

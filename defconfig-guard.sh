#!/bin/bash
# =========================================================
# defconfig 防呆检查 v2
# 在 "make defconfig" 前后，检查用户在 profile 里显式 =y 的包
# 是否还存在（=y 或 =m 都算存在）。
#
# 为什么只按符号名检查、不按 "=y/=m" 整行比：
#   基座是全量多机型配置，同一符号在基座里 =m、profile 里 =y 是常态，
#   defconfig 取最后值(=y)。按整行比会把已解决的 =m 行误报为"被剔除"。
#
# 判定规则：
#   - diy 已放源码到 package/custom/ 但最终丢失 → 硬错误（nikki 那类 bug）
#   - 其他（如上游改名/删除导致的过时符号）→ 只警告，不阻断构建
#
# 调用方式（在 $BUILD_ROOT/openwrt 下执行）：
#   chmod +x "$GITHUB_WORKSPACE/defconfig-guard.sh"
#   "$GITHUB_WORKSPACE/defconfig-guard.sh"
# 需要环境变量：GITHUB_WORKSPACE、CONFIG_FILE（均由 workflow 提供）
# =========================================================

WANT=/tmp/want_pkgs.txt
grep -oE '^CONFIG_PACKAGE_[A-Za-z0-9_.-]+=y' "$GITHUB_WORKSPACE/${CONFIG_FILE:?CONFIG_FILE 未设置}" 2>/dev/null \
  | sed 's/=y$//' | sort -u > "$WANT" || true
# diy-part2.sh 后追加的包也纳入
printf '%s\n' CONFIG_PACKAGE_iw CONFIG_PACKAGE_zoneinfo-asia >> "$WANT"
sort -u "$WANT" -o "$WANT"

echo "===== make defconfig ====="
make defconfig 2>&1 | tail -5

MISSING=""; STALE=""
while IFS= read -r sym; do
  [ -z "$sym" ] && continue
  if ! grep -q "^${sym}=[ym]" .config; then
    pkg="${sym#CONFIG_PACKAGE_}"
    if [ -d "package/custom/$pkg" ]; then
      MISSING="$MISSING $pkg"
    else
      STALE="$STALE $pkg"
    fi
  fi
done < "$WANT"

if [ -n "$STALE" ]; then
  echo "::warning::以下符号在 defconfig 后不存在（上游改名/删除，或源码未提供）：$STALE"
fi
if [ -n "$MISSING" ]; then
  echo "::error::diy 已提供源码，但以下包在 defconfig 后丢失：$MISSING"
  exit 1
fi
echo "✅ defconfig 检查通过"

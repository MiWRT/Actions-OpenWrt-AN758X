#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# 把 LuCI 概览页「CPU 使用率（%）」那一行的取值命令改指到 /sbin/cpuusage
#
# 被谁调用：diy-part2.sh（.config 加载之后、任何包编译之前）
#
# =========================================================
# 这条链路是怎么串起来的（改之前务必读一遍）
# =========================================================
#
#  文案 + 渲染   luci-mod-status/htdocs/.../view/status/include/10_system.js
#                  _('CPU usage (%)'),  cpuusage.cpuusage
#  取值           luci-base 的 rpcd ucode 脚本 luci.getCPUUsage：
#                  const fd = popen('top -n1 | awk \'/^CPU/ {printf("%d%", 100 - $8)}\'');
#  授权           luci-mod-status 的 acl.d：luci [ "getCPUUsage" ]
#
# 前端是「rpcd 返回什么就原样塞进单元格」，所以只换掉 popen 里的命令即可，
# 前端与 ACL 一行都不用动 —— luci.getCPUUsage 在 LuCI 里只有这一个调用方
# （immortalwrt/luci 全仓库引用它的只有：rpcd 实现、10_system.js、acl.d 三处）。
#
# 为什么不「用 files/ 覆盖整个 10_system.js」：
#   那等于把 LuCI 的核心文件整份抄进本仓库，上游一改（加字段、调整渲染顺序）
#   就会悄悄落后。这里只动一个命令字符串，改动面最小、前端保持上游原样。
#
# 为什么写成 `sh /sbin/cpuusage` 而不是直接 `/sbin/cpuusage`：
#   和 luci-app-pon-status 调 ponstat-conn 同样的考虑 —— 直接 exec 要求目标带
#   可执行位，而这个位在「Windows 打包 / 解压 / git checkout」链路上反复丢失。
#   经 /bin/sh 读脚本内容就不依赖它了。
#
# 失败处理：这纯粹是显示层的东西，所以
#   * 数据源 files/sbin/cpuusage 不在 → 直接跳过，不打补丁
#     （打了反而会让这一行退化成 "?"，因为 /sbin/cpuusage 不存在）
#   * 找不到目标 / 没匹配上命令行 → 只 ::warning::，不中断编译
#   两种情况的代价都只是：概览页维持原来的单个总占用率。
# =========================================================

set -uo pipefail

PONWRT_DIR="${PONWRT_DIR:-.}"

# 旧实现里的取值命令。
# 用固定串（-F）做检测与打印，避免 BRE/ERE 下 "(" 的转义坑。
OLD_FIX="popen('top -n1"
NEW_FIX="popen('sh /sbin/cpuusage')"
NEW_CALL="${NEW_FIX};"

if ! cd "$PONWRT_DIR" 2>/dev/null; then
	echo "::warning::PONWRT_DIR 无效（$PONWRT_DIR），跳过 CPU 使用率行定制"
	exit 0
fi

echo "=========================================="
echo "概览页 CPU 使用率行：改指 /sbin/cpuusage"
echo "=========================================="

# ---------------------------------------------------------
# 0. 数据源必须在位 —— 否则补丁会把这一行变成 "?"
# ---------------------------------------------------------
if [ ! -f files/sbin/cpuusage ]; then
	echo "::warning::files/sbin/cpuusage 不存在（files/ 还没被拷进源码树？）"
	echo "::warning::跳过补丁，概览页「CPU 使用率（%）」维持原始显示"
	exit 0
fi
echo "✅ 数据源: files/sbin/cpuusage  ->  /sbin/cpuusage"

# ---------------------------------------------------------
# 1. 找目标：luci-base 的 rpcd ucode 实现
#    monorepo 里在 feeds/luci/modules/luci-base/root/usr/share/rpcd/ucode/luci，
#    但不同 fork 的层级可能不同，所以按路径尾巴找，再按内容确认。
#    带 -L：万一某天 feeds/luci 变成符号链接也不会漏掉（重复命中有幂等分支兜住）。
# ---------------------------------------------------------
TARGETS=()
while IFS= read -r f; do
	[ -n "$f" ] && TARGETS+=("$f")
done < <(find -L feeds -type f -path '*rpcd/ucode/luci' 2>/dev/null | sort)

if [ "${#TARGETS[@]}" -eq 0 ]; then
	echo "::warning::feeds/ 下找不到 *rpcd/ucode/luci（LuCI 版本 / fork 不同？）"
	echo "::warning::概览页「CPU 使用率（%）」维持原始显示（单个总占用率）"
	exit 0
fi

# ---------------------------------------------------------
# 2. 打补丁：只替换 popen(...) 这一个调用（到第一个分号为止），
#    文件其它部分一律不碰
# ---------------------------------------------------------
patched=0

for f in "${TARGETS[@]}"; do
	# 只处理真正实现了 getCPUUsage 的那一份
	if ! grep -q 'getCPUUsage' "$f" 2>/dev/null; then
		echo "  -  跳过（无 getCPUUsage）: $f"
		continue
	fi

	# 幂等：已经是目标状态就直接算数
	if grep -qF "$NEW_FIX" "$f"; then
		echo "  =  已是目标状态，跳过: $f"
		patched=$((patched + 1))
		continue
	fi

	if ! grep -qF "$OLD_FIX" "$f"; then
		echo "::warning::$f 里有 getCPUUsage，但没有预期的 top 命令行，未改动"
		echo "          （上游改了实现？请同步本脚本的 OLD_FIX/NEW_FIX）"
		continue
	fi

	echo "  目标: $f"
	echo "  修改前: $(grep -m1 -nF "$OLD_FIX" "$f" | sed 's/^[[:space:]]*//')"

	# [^;]* 只会跨过一个 popen 调用（该命令串里不含分号），
	# 所以不会误伤文件里其它 popen(...)
	sed -i "s@popen('top -n1[^;]*;@${NEW_CALL}@" "$f"

	if grep -qF "$NEW_FIX" "$f"; then
		echo "  修改后: $(grep -m1 -nF "$NEW_FIX" "$f" | sed 's/^[[:space:]]*//')"
		echo "  ✅ 已改指"
		patched=$((patched + 1))
	else
		echo "::warning::替换没有生效: $f"
	fi
done

if [ "$patched" -eq 0 ]; then
	echo "::warning::没有任何目标被改动，概览页 CPU 行维持原始显示"
	exit 0
fi

echo "------------------------------------------"
echo "共处理 $patched 处；概览页「CPU 使用率（%）」将显示："
echo "  USR: x% SYS: y% · C0 u%/s% C1 u%/s% ..."
echo "------------------------------------------"
echo "🎉 patch-luci-cpuusage.sh 执行完毕"

exit 0

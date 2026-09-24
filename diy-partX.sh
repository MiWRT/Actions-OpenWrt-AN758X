#!/bin/bash
# ================================================================
# diy-partX.sh —— 最后一步收尾（对应 798X 仓库的 diy-partX.sh）
# 运行目录: ponwrt 源码根目录
# 职责: 斩断 Ruby->Rust 依赖链（避免超长的 Rust 编译）、清理冲突
# ================================================================

echo "=========================================="
echo "执行收尾脚本 (diy-partX.sh)"
echo "=========================================="

# ---------------------------------------------------------
# 方案 A：配置层强制关闭 RUBY_ENABLE_YJIT
# ---------------------------------------------------------
for conf in .config; do
  if [ -f "$conf" ]; then
    sed -i '/CONFIG_RUBY_ENABLE_YJIT/d' "$conf"
    echo "# CONFIG_RUBY_ENABLE_YJIT is not set" >> "$conf"
    echo "✅ 方案 A: $conf 已关闭 RUBY_ENABLE_YJIT"
  fi
done

# ---------------------------------------------------------
# 方案 B：Makefile 物理切断依赖
# ---------------------------------------------------------
RUBY_MK=$(find feeds -type f -path "*/lang/ruby/Makefile" 2>/dev/null | head -n 1)
if [ -f "$RUBY_MK" ]; then
  sed -i '/config RUBY_ENABLE_YJIT/,/help/{s/default y.*/default n/g}' "$RUBY_MK"
  echo "✅ 方案 B: Ruby 对 Rust 的依赖链已切断"
else
  echo "⚠️ 未找到 Ruby Makefile，方案 B 跳过"
fi

# ---------------------------------------------------------
# 清理：删除 feeds 中与 ponwrt 冲突的旧版 PON 组件（如存在）
# ---------------------------------------------------------
find feeds package -maxdepth 3 -type d -name "luci-app-pon-old" -exec rm -rf {} + 2>/dev/null

echo "🎉 diy-partX.sh 执行完毕"

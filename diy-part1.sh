#!/bin/bash
# ================================================================
# diy-part1.sh —— feeds 安装之后、加载 .config 之前执行
# 运行目录: ponwrt 源码根目录
# 职责: 追加第三方源 / 修正 feeds / 编译环境准备
# ================================================================

echo "=========================================="
echo "执行自定义脚本 (diy-part1.sh)"
echo "=========================================="

# --- git 身份，避免某些包 build 时报错 ---
git config --global user.name  "PonWrt CI"
git config --global user.email "ci@ponwrt.local"
git config --global core.autocrlf input

# ---------------------------------------------------------
# 1. feeds 来源控制
#    ponwrt 自带 feeds.conf.default 中：
#      packages / luci            -> ImmortalWrt  ✔ 保留
#      pon_drivers / pon_userspace-> ponwrt PON   ✔ 保留
#      routing / telephony / video-> OpenWrt 官方
#    默认保留源自带配置。改成 true 即剔除 OpenWrt 官方三条 feed，
#    编译范围严格限定在 ImmortalWrt + ponwrt 组件内。
# ---------------------------------------------------------
STRIP_OPENWRT_FEEDS=false

if [ "$STRIP_OPENWRT_FEEDS" = "true" ]; then
  sed -i '/^src-git[[:space:]]*\(routing\|telephony\|video\)[[:space:]]/d' feeds.conf.default
  echo "✅ 已剔除 OpenWrt 官方 feed（routing / telephony / video）"
fi

# ---------------------------------------------------------
# 2. 追加第三方 feeds（默认关闭，需要时把 false 改 true）
# ---------------------------------------------------------
ADD_EXTRA_FEEDS=false

if [ "$ADD_EXTRA_FEEDS" = "true" ]; then
  cat >> feeds.conf.default <<'EOF'
src-git helloworld https://github.com/fw876/helloworld.git
src-git passwall_packages https://github.com/xiaorouji/openwrt-passwall-packages.git
EOF
  ./scripts/feeds update -a
  ./scripts/feeds install -a
  echo "✅ 第三方 feeds 已追加"
fi

# ---------------------------------------------------------
# 2. ponwrt 专用 feeds 检查（PON 驱动 / 用户态必须存在）
# ---------------------------------------------------------
for f in pon_drivers pon_userspace; do
  if [ ! -d "feeds/$f" ]; then
    echo "::warning::缺少 feed: $f —— LuCI 的 PON 配置项可能缺失"
  fi
done

# ---------------------------------------------------------
# 3. 已知编译问题预处理
# ---------------------------------------------------------
# libxcrypt: -fcommon + 关闭 werror，避免 host 工具链编译中断
XCRYPT_MK="feeds/packages/libs/libxcrypt/Makefile"
if [ -f "$XCRYPT_MK" ]; then
  sed -i 's/CONFIGURE_ARGS[ \t]*+=[ \t]*/&--disable-werror /' "$XCRYPT_MK"
  sed -i 's/TARGET_CFLAGS[ \t]*+=[ \t]*/&-fcommon /' "$XCRYPT_MK"
  echo "✅ libxcrypt 参数已硬化"
fi

# Rust: 强制本地编 LLVM，避免下载预编译 LLVM 失败
RUST_MK=$(find feeds -type f -path "*/lang/rust/Makefile" 2>/dev/null | head -n1)
if [ -f "$RUST_MK" ]; then
  sed -i 's/download-ci-llvm=true/download-ci-llvm=false/g' "$RUST_MK"
  echo "✅ Rust 已设为本地编译 LLVM"
fi

echo "🎉 diy-part1.sh 执行完毕"

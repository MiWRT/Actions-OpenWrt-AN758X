#!/bin/bash
# ================================================================
# diy-part3.sh —— 可选插件拉取（diy-part2 之后、defconfig 之前）
# 运行目录: ponwrt 源码根目录
# 职责: 拉取 feeds 里没有的第三方插件到 package/custom，处理版本冲突
# 默认全部关闭：把需要的开关改成 true 即可
# ================================================================

echo "=========================================="
echo "执行可选插件拉取 (diy-part3.sh)"
echo "=========================================="

PKG_DIR="package/custom"
mkdir -p "$PKG_DIR"

# ---------------------------------------------------------
# 0. 开关区
# ---------------------------------------------------------
ADD_ARGON=true        # sbwml 新版 argon 主题（会替换 feeds 里的旧版）
ADD_PASSWALL=false    # luci-app-passwall + passwall-packages 依赖
ADD_OPENCLASH=false   # luci-app-openclash（依赖 Ruby/Rust，编译很慢）
ADD_MOSDNS=false      # luci-app-mosdns + mosdns 核心
ADD_LUCKY=false       # luci-app-lucky
ADD_TAILSYALE=false   # luci-app-tailscale

clone() {  # clone <url> <dir> [branch]
  local url="$1" dir="$2" br="$3"
  if [ -d "$dir" ]; then
    echo "已存在，跳过: $dir"
    return 0
  fi
  if [ -n "$br" ]; then
    git clone --depth 1 -b "$br" "$url" "$dir"
  else
    git clone --depth 1 "$url" "$dir"
  fi
  [ $? -eq 0 ] && echo "✅ $dir" || echo "::warning::克隆失败 $url"
}

# ---------------------------------------------------------
# 1. Argon 主题：先删 feeds 旧版，避免同名包冲突
# ---------------------------------------------------------
if [ "$ADD_ARGON" = "true" ]; then
  if [ -d "feeds/luci/themes/luci-theme-argon" ]; then
    rm -rf feeds/luci/themes/luci-theme-argon
    echo "✅ 已移除 feeds 旧版 luci-theme-argon"
  fi
  clone https://github.com/sbwml/luci-theme-argon "$PKG_DIR/luci-theme-argon" openwrt-24.10
  clone https://github.com/sbwml/luci-app-argon-config "$PKG_DIR/luci-app-argon-config" master
fi

# ---------------------------------------------------------
# 2. Passwall（含依赖源）
# ---------------------------------------------------------
if [ "$ADD_PASSWALL" = "true" ]; then
  clone https://github.com/xiaorouji/openwrt-passwall-packages "$PKG_DIR/openwrt-passwall-packages" main
  clone https://github.com/xiaorouji/openwrt-passwall "$PKG_DIR/openwrt-passwall" main
  # 只保留 luci-app-passwall，避免 passwall2 等重复包进菜单
  rm -rf "$PKG_DIR/openwrt-passwall/luci-app-passwall2" 2>/dev/null
fi

# ---------------------------------------------------------
# 3. OpenClash
# ---------------------------------------------------------
if [ "$ADD_OPENCLASH" = "true" ]; then
  echo "::warning::OpenClash 会触发 Ruby/Rust 编译，耗时极长，建议单独构建"
  clone https://github.com/vernesong/OpenClash "$PKG_DIR/OpenClash" master
  mv "$PKG_DIR/OpenClash/luci-app-openclash" "$PKG_DIR/luci-app-openclash" 2>/dev/null
  rm -rf "$PKG_DIR/OpenClash"
fi

# ---------------------------------------------------------
# 4. mosdns
# ---------------------------------------------------------
if [ "$ADD_MOSDNS" = "true" ]; then
  clone https://github.com/sbwml/luci-app-mosdns "$PKG_DIR/luci-app-mosdns" v5
  clone https://github.com/sbwml/v2ray-geodata "$PKG_DIR/v2ray-geodata" master
fi

# ---------------------------------------------------------
# 5. lucky
# ---------------------------------------------------------
if [ "$ADD_LUCKY" = "true" ]; then
  clone https://github.com/sirpdboy/luci-app-lucky "$PKG_DIR/luci-app-lucky" main
fi

# ---------------------------------------------------------
# 6. tailscale
# ---------------------------------------------------------
if [ "$ADD_TAILSYALE" = "true" ]; then
  clone https://github.com/asvow/luci-app-tailscale "$PKG_DIR/luci-app-tailscale" main
fi

# ---------------------------------------------------------
# 7. 让新包进入索引
# ---------------------------------------------------------
if [ -n "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then
  ./scripts/feeds update -i 2>/dev/null || true
  ./scripts/feeds install -a >/dev/null 2>&1 || true
  echo "✅ package/custom 内容："
  ls -1 "$PKG_DIR"
else
  echo "未启用任何第三方插件，package/custom 为空"
fi

echo "🎉 diy-part3.sh 执行完毕"

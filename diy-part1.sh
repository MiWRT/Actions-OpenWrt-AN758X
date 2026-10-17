#!/bin/bash
# ================================================================
# diy-part1.sh —— 只做一件事：拉取可选插件到 package/custom
# 运行目录: ponwrt 源码根目录（feeds 安装之后、加载 .config 之前）
#
# 用法：把需要的插件开关改成 true，再到 configs/<机型>.config 里
#       把对应 "# CONFIG_PACKAGE_xxx is not set" 改成 "=y"
# ================================================================

echo "=========================================="
echo "拉取可选插件 (diy-part1.sh)"
echo "=========================================="

PKG_DIR="package/custom"
mkdir -p "$PKG_DIR"

# ---------------------------------------------------------
# 临时固定 Go 为 1.27.1（不要用 1.27.2）
#
# 原因：feeds/packages 在 2026-10-13 把 golang 从 1.27.1 升到 1.27.2
# （openwrt/packages commit 0ee3fbc，安全修复），之后 mihomo-meta
# 编译失败：Go 报「build constraints exclude all Go files in
# metacubex/http@v0.1.8/internal/filepath」，随后大量
# 「no required module provides package …」。
# 上一次成功构建（run #46，2026-10-13）用的是 1.27.1。
#
# 等上游（openwrt/packages 或 mihomo）修复 1.27.2 兼容后再去掉
# 本段。只针对已知的坏版本 1.27.2，1.27.3+ 不动。
#
# 注意：pin 带校验（应用后立即验证 PATCH/HASH），若校验失败
# 立刻报错退出，不让构建白跑 2 小时后才在 mihomo-meta 挂掉。
# ---------------------------------------------------------
GO_MK="feeds/packages/lang/golang/golang1.27/Makefile"
GO_PIN_HASH="4e408abae126d916b6164627193f2c54f0e3ca1312d693b86db45f862ab238b1"  # Go 1.27.1 官方 hash
if [ -f "$GO_MK" ]; then
  GO_PATCH_NOW="$(grep -E '^GO_VERSION_PATCH:=' "$GO_MK" | head -1 | sed 's/.*:=//' | tr -d '[:space:]')"
  if [ "$GO_PATCH_NOW" = "2" ]; then
    sed -i -E 's/^GO_VERSION_PATCH:=.*/GO_VERSION_PATCH:=1/' "$GO_MK"
    sed -i -E "s/^PKG_HASH:=.*/PKG_HASH:=$GO_PIN_HASH/" "$GO_MK"
    GO_PATCH_AFTER="$(grep -E '^GO_VERSION_PATCH:=' "$GO_MK" | head -1 | sed 's/.*:=//' | tr -d '[:space:]')"
    GO_HASH_AFTER="$(grep -E '^PKG_HASH:=' "$GO_MK" | head -1 | sed 's/.*:=//' | tr -d '[:space:]')"
    if [ "$GO_PATCH_AFTER" = "1" ] && [ "$GO_HASH_AFTER" = "$GO_PIN_HASH" ]; then
      echo "✅ golang 固定回 1.27.1（1.27.2 编 mihomo-meta 失败，已绕过）"
    else
      echo "::error::Go pin 校验失败：PATCH=$GO_PATCH_AFTER（期望 1），请检查 $GO_MK"
      exit 1
    fi
  elif [ "$GO_PATCH_NOW" = "1" ]; then
    echo "ℹ️ golang 已是 1.27.1，pin 无需重复应用"
  else
    echo "::warning::golang1.27 的 PATCH=$GO_PATCH_NOW（不是 1.27.2），pin 未应用；若 mihomo-meta 失败请检查 Go 版本"
  fi
else
  echo "::warning::未找到 $GO_MK，Go pin 未应用；若 mihomo-meta 失败请检查 feeds"
fi

# ---------------------------------------------------------
# Go 模块下载：允许 Go 下载缺失的依赖（解决 mihomo-meta 编译失败）
#
# 现象：mihomo-meta 编译时报大量「no required module provides package」
# （sing/common、tailscale、zerotier-go 等），且无下载/校验报错。
# 根因：Go 找不到 mihomo 的依赖模块——本地模块缓存（dl/go-mod-cache）
# 里没有，且默认的 -mod=readonly 模式不允许 Go 下载缺失模块。
#
# 修复：通过 $GITHUB_ENV 把 GOFLAGS/GOPROXY 写给后续步骤（含 Compile）：
#   GOFLAGS=-mod=mod              允许 Go 下载缺失模块（默认 readonly 会直接报错）
#   GOPROXY=goproxy.cn + 官方代理 + direct   多个镜像兜底
#   GOSUMDB=off                  跳过 sumdb 在线校验（go.sum 本身仍校验）
#
# 注意：只影响 Go 模块下载，不影响源码与固件内容。
# ---------------------------------------------------------
if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "GOFLAGS=-mod=mod"
    echo "GOPROXY=https://goproxy.cn,https://proxy.golang.org,direct"
    echo "GOSUMDB=off"
  } >> "$GITHUB_ENV"
  echo "✅ Go 模块下载已配置（GOFLAGS=-mod=mod，GOPROXY=goproxy.cn 兜底）"
else
  echo "::warning::未找到 \$GITHUB_ENV，Go 模块下载配置未写入（非 Actions 环境？）"
fi

# ---------------------------------------------------------
# 清理损坏的 Go 模块缓存（解决 mihomo-meta/yq 编译失败）
#
# 现象：mihomo-meta 编译时报大量「undefined: xxx」（gobwas/pool、
# go-krypto、go-ps、cbor 等依赖），yq 也挂。根因：dl/go-mod-cache
#（随 dl 缓存跨构建持久化）里的模块文件损坏——不同版本的依赖
# 文件混在一起，go build 拿到的是"缝合怪"。
#
# 修复：构建前删掉整个 go-mod-cache，让 Go 重新下载。虽然这次构建
# 的 Go 包编译会慢一些（要重新下载模块），但能保证依赖是干净的。
# 下次构建时缓存又是好的，速度恢复正常。
# ---------------------------------------------------------
if [ -d "dl/go-mod-cache" ]; then
  rm -rf dl/go-mod-cache
  echo "✅ 已清理 Go 模块缓存（dl/go-mod-cache），将重新下载依赖"
fi

# ---------------------------------------------------------
# 插件开关
# 默认开启：Airoha SoC 状态页（config 里已 =y，必须拉否则 defconfig 会剔除）
#
# 温度不再用 luci-app-temp-status —— 由 autocore 的 /sbin/tempinfo 提供，
# 见 files/sbin/tempinfo（概览页「温度」行：CPU / WiFi / PON 温度 + 光功率）
# ---------------------------------------------------------
ADD_AIROHA_NPU=true    # luci-app-airoha-npu：Airoha SoC 状态页（NPU/CPU/Frame Engine/PPE）

ADD_PASSWALL=false     # luci-app-passwall（含依赖源）
ADD_OPENCLASH=false    # luci-app-openclash ⚠ 依赖 Ruby/Rust，编译极慢
ADD_MOSDNS=false       # luci-app-mosdns + v2ray-geodata
ADD_LUCKY=true         # luci-app-lucky（DDNS + socat）
ADD_TAILSCALE=false    # luci-app-tailscale
ADD_OPENLIST=false     # luci-app-openlist2（alist/openlist 挂载）
ADD_SMARTDNS=false     # luci-app-smartdns

ADD_LUCI_APP=true       # qwe3017/luci-app 仓库（monorepo）
                        #   ├─ luci-app-natmode     NAT 类型三选一（网络 → NAT 类型）
                        #   └─ luci-app-pon-status  PON 光模块卡片（概览页「系统」下一格）

clone() {  # clone <url> <dir> [branch]
  local url="$1" dir="$2" br="$3"
  [ -d "$dir" ] && { echo "已存在，跳过: $dir"; return 0; }
  echo "--- git clone $url -> $dir ---"
  if [ -n "$br" ]; then
    git clone --depth 1 -b "$br" "$url" "$dir" 2>&1 | tail -3
  else
    git clone --depth 1 "$url" "$dir" 2>&1 | tail -3
  fi
  if [ -d "$dir" ]; then
    echo "✅ 克隆成功: $dir"
    return 0
  fi
  echo "::error::克隆失败: $url"
  return 1
}

# =========================================================
# qwe3017/luci-app —— 两个 LuCI 插件的来源
#
# 这是一个 monorepo，结构为：
#   luci-app/
#   ├── luci-app-natmode/
#   └── luci-app-pon-status/
# =========================================================
if [ "$ADD_LUCI_APP" = "true" ]; then
  LUCI_APP_URL="https://github.com/qwe3017/luci-app"
  LUCI_APP_TMP="$(mktemp -d)/luci-app"

  if ! clone "$LUCI_APP_URL" "$LUCI_APP_TMP" main; then
    echo "::error::qwe3017/luci-app 拉取失败，natmode / pon-status 会被 defconfig 剔除"
    exit 1
  fi

  for p in luci-app-natmode luci-app-pon-status; do
    if [ ! -f "$LUCI_APP_TMP/$p/Makefile" ]; then
      echo "::error::$LUCI_APP_TMP/$p/Makefile 不存在，包无法被索引"
      exit 1
    fi
    rm -rf "$PKG_DIR/$p"
    cp -r "$LUCI_APP_TMP/$p" "$PKG_DIR/"
    echo "✅ 已拷贝: $p  (版本 $(grep -m1 '^PKG_VERSION' "$PKG_DIR/$p/Makefile" 2>/dev/null | sed 's/PKG_VERSION:=//'))"
  done

  rm -rf "$LUCI_APP_TMP"
fi

# --- Airoha SoC 状态页（NPU 卸载 / CPU 频率 / Frame Engine / PPE 流表）---
# 包名由目录名决定（luci.mk: PKG_NAME ?= $(notdir ${CURDIR})），
# 目录必须是 luci-app-airoha-npu，否则 config 里的符号对不上。
#
# 源用 luanmuc/luci-app-airoha-npu（rchen14b 的 fork 改进版）：
#   - 自带 po/zh_Hans 完整中文翻译（48 条）
#   - 无 rchen14b 那种「根目录 + 同名子目录」重复结构，feed 索引不会中断
#   - 修了 luci.mk 的 include 路径、加了独立 CPU 温度与 PLL 备用频率
if [ "$ADD_AIROHA_NPU" = "true" ]; then
  if ! clone https://github.com/luanmuc/luci-app-airoha-npu "$PKG_DIR/luci-app-airoha-npu" main; then
    echo "::error::luci-app-airoha-npu 拉取失败，后续 defconfig 会静默剔除该包"
    exit 1
  fi

  # 包名校验：Makefile 必须存在，否则 buildroot 扫不到这个包
  if [ ! -f "$PKG_DIR/luci-app-airoha-npu/Makefile" ]; then
    echo "::error::$PKG_DIR/luci-app-airoha-npu/Makefile 不存在，包无法被索引"
    exit 1
  fi
  echo "   版本: $(grep -m1 '^PKG_VERSION' "$PKG_DIR/luci-app-airoha-npu/Makefile" 2>/dev/null)"

  # =========================================================
  # 关键：po 文件名必须改成 airoha-npu.po
  #
  # luci.mk 的 i18n install 规则：
  #   po2lmo $(po) → $(LUCI_LIBRARYDIR)/i18n/$(basename $(notdir $(po))).$(lang).lmo
  # 即 lmo 名取自 po 文件主名。而运行时按
  #   LUCI_BASENAME = $(patsubst luci-app-%,%,luci-app-airoha-npu) = airoha-npu
  # 查找 lmo。上游两份 po 都叫 luci-app-airoha-npu.po，
  # 会生成 luci-app-airoha-npu.zh-cn.lmo，前端找不到 → 中文不生效。
  # 官方 app 都是 basename 命名（firewall.po / package-manager.po / pon.po）。
  # =========================================================
  PODIR="$PKG_DIR/luci-app-airoha-npu/po"
  if [ -f "$PODIR/zh_Hans/luci-app-airoha-npu.po" ]; then
    # 确保 Language 头是 zh_Hans（上游头部缺该字段时 po2lmo 可能识别异常）
    grep -q '^"Language:' "$PODIR/zh_Hans/luci-app-airoha-npu.po" || \
      sed -i 's/^msgstr ""$/msgstr ""\n"Language: zh_Hans\\n"/' "$PODIR/zh_Hans/luci-app-airoha-npu.po"
    mv "$PODIR/zh_Hans/luci-app-airoha-npu.po" "$PODIR/zh_Hans/airoha-npu.po"
    echo "✅ po 改名: luci-app-airoha-npu.po -> airoha-npu.po（luci.mk 按 LUCI_BASENAME 查找）"
  fi
  if [ -f "$PODIR/es/luci-app-airoha-npu.po" ]; then
    mv "$PODIR/es/luci-app-airoha-npu.po" "$PODIR/es/airoha-npu.po"
  fi
  echo "   po/zh_Hans: $(ls -1 "$PODIR/zh_Hans/" 2>/dev/null | tr '\n' ' ')"
fi

# --- passwall ---
if [ "$ADD_PASSWALL" = "true" ]; then
  clone https://github.com/xiaorouji/openwrt-passwall-packages "$PKG_DIR/openwrt-passwall-packages" main
  clone https://github.com/xiaorouji/openwrt-passwall "$PKG_DIR/openwrt-passwall" main
  rm -rf "$PKG_DIR/openwrt-passwall/luci-app-passwall2" 2>/dev/null
fi

# --- openclash ---
if [ "$ADD_OPENCLASH" = "true" ]; then
  echo "::warning::OpenClash 会触发 Ruby/Rust 编译，耗时极长"
  clone https://github.com/vernesong/OpenClash "$PKG_DIR/OpenClash" master
  mv "$PKG_DIR/OpenClash/luci-app-openclash" "$PKG_DIR/luci-app-openclash" 2>/dev/null
  rm -rf "$PKG_DIR/OpenClash"
fi

# --- mosdns ---
if [ "$ADD_MOSDNS" = "true" ]; then
  clone https://github.com/sbwml/luci-app-mosdns "$PKG_DIR/luci-app-mosdns" v5
  clone https://github.com/sbwml/v2ray-geodata "$PKG_DIR/v2ray-geodata" master
fi

# --- lucky ---
# 注意：sirpdboy/luci-app-lucky 仓库是嵌套结构，真正的包在子目录里：
#   luci-app-lucky/luci-app-lucky/  → LuCI 界面（PKG_NAME:=luci-app-lucky，依赖 +lucky）
#   luci-app-lucky/lucky/           → 核心二进制（PKG_NAME:=lucky）
# 必须把两个子目录分别挪到 package/custom/ 下，否则 defconfig 找不到包。
if [ "$ADD_LUCKY" = "true" ]; then
  LUCKY_TMP="$(mktemp -d)/lucky-src"
  if ! clone https://github.com/sirpdboy/luci-app-lucky "$LUCKY_TMP" main; then
    echo "::error::luci-app-lucky 拉取失败"
    exit 1
  fi
  for p in lucky luci-app-lucky; do
    if [ ! -f "$LUCKY_TMP/$p/Makefile" ]; then
      echo "::error::$LUCKY_TMP/$p/Makefile 不存在，包无法被索引"
      exit 1
    fi
    rm -rf "$PKG_DIR/$p"
    cp -r "$LUCKY_TMP/$p" "$PKG_DIR/"
    echo "✅ 已拷贝: $p"
  done
  rm -rf "$(dirname "$LUCKY_TMP")"
fi

# --- tailscale ---
if [ "$ADD_TAILSCALE" = "true" ]; then
  clone https://github.com/asvow/luci-app-tailscale "$PKG_DIR/luci-app-tailscale" main
fi

# --- openlist2 ---
if [ "$ADD_OPENLIST" = "true" ]; then
  clone https://github.com/sbwml/luci-app-openlist2 "$PKG_DIR/luci-app-openlist2" main
fi

# --- smartdns ---
if [ "$ADD_SMARTDNS" = "true" ]; then
  clone https://github.com/pymumu/luci-app-smartdns "$PKG_DIR/luci-app-smartdns" master
  clone https://github.com/pymumu/smartdns "$PKG_DIR/smartdns" master
fi

# ---------------------------------------------------------
# 校验：默认开启的两个插件必须拉到，否则 defconfig 会静默剔除，
#       编出来的固件缺少状态页还不易察觉
# ---------------------------------------------------------
if [ "$ADD_AIROHA_NPU" = "true" ] && [ ! -d "$PKG_DIR/luci-app-airoha-npu" ]; then
  echo "::error::luci-app-airoha-npu 未拉到，config 里的 =y 会被 defconfig 剔除"
  exit 1
fi

# natmode / pon-status 来自 qwe3017/luci-app（config 里也是 =y）
for p in luci-app-natmode luci-app-pon-status; do
  if [ "$ADD_LUCI_APP" = "true" ] && [ ! -d "$PKG_DIR/$p" ]; then
    echo "::error::$p 未拉到，config 里的 =y 会被 defconfig 剔除"
    exit 1
  fi
done

# ---------------------------------------------------------
# 清理重复嵌套目录
# rchen14b/luci-app-airoha-npu 这个仓库有问题：包在根目录放了一份，
# 又在同名子目录 luci-app-airoha-npu/ 里放了完整一份（含 Makefile）。
# feeds 扫描会把两层都当成独立包，内层 dump 失败（报
# "feeds/custom/luci-app-airoha-npu/luci-app-airoha-npu"）会中断整个
# custom feed 的索引，导致 package/feeds/custom 压根不生成，
# 所有包符号都不存在。
# ---------------------------------------------------------
echo "--- 检查重复嵌套目录 ---"
for d in "$PKG_DIR"/*; do
  [ -d "$d" ] || continue
  n=$(basename "$d")
  if [ -d "$d/$n" ] && [ -f "$d/$n/Makefile" ]; then
    rm -rf "$d/$n"
    echo "✅ 已移除重复嵌套目录: $n/$n"
  fi
done

# ---------------------------------------------------------
# 让新包进入索引
#
#   ⚠️ 判据是 tmp/.packageinfo，不是 package/feeds/custom
#
#   OpenWrt 的 prepare-tmpinfo 直接扫 package/ 目录树：
#     include/scan.mk:  find -L package -mindepth 1 -maxdepth 5 -name Makefile
#   package/custom/<pkg>/Makefile 深度只有 3，本来就会被扫到，
#   **根本不需要注册 feed**。
#
#   以前那套 src-link custom feed 有两个问题：
#     ① feeds/custom 指向 package/custom，而 feeds/base 已经指向 ../package，
#        同一批 Makefile 被扫两遍，package-metadata.pl 按 Override 挑一个，
#        行为随扫描顺序漂移；
#     ② scripts/feeds 的 install_src() 里，$installed{$name} 已经非空
#        （就是 ① 扫出来的那份），于是直接 return 0，压根不建
#        package/feeds/custom/<pkg> 符号链接 ——
#        所以「package/feeds/custom 不存在」是**正常现象**，不是索引失败。
#        拿它当判据必然误报。
# ---------------------------------------------------------
if [ -n "$(ls -A "$PKG_DIR" 2>/dev/null)" ]; then

  # =========================================================
  # 强制重建索引
  #   只删 tmp/.packageinfo 是不够的：prepare-tmpinfo 有 scan_unchanged
  #   优化（拿 tmp/info/.scan-*.stamp 比 mtime），stamp 还在且没有更新的
  #   Makefile 时它会跳过扫描 —— 结果 .packageinfo 被删了却没人重建，
  #   索引反而空了。所以 stamp 也要一起删。
  # =========================================================
  rm -f tmp/.packageinfo tmp/.targetinfo
  rm -f tmp/info/.scan-packageinfo.stamp tmp/info/.scan-targetinfo.stamp
  rm -f tmp/.config-package.in tmp/.config-target.in

  echo ">>> make prepare-tmpinfo（重新扫描 package/ 树）"
  make -s prepare-tmpinfo OPENWRT_BUILD= 2>&1 | tail -5 || true

  echo "=========================================="
  echo "包索引校验（判据：tmp/.packageinfo）"
  echo "=========================================="
  echo "package/custom 内容："
  INDEX_MISS=""
  for d in "$PKG_DIR"/*; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    if [ ! -f "$d/Makefile" ]; then
      echo "  -  $n（无根 Makefile，视为源仓库/子包容器，跳过）"
      continue
    fi
    # 目录名即包名：buildroot 约定 PKG_NAME ?= $(notdir ${CURDIR})
    if grep -qx "Package: $n" tmp/.packageinfo 2>/dev/null; then
      echo "  ✅ $n"
    else
      echo "  ❌ $n —— tmp/.packageinfo 里查不到"
      INDEX_MISS="$INDEX_MISS $n"
      # 真实错误在这里（scan.mk 落盘路径 logs/<SCAN_DIR>/<相对目录>/dump.txt）
      for f in "logs/package/$n/dump.txt" "logs/package/custom/$n/dump.txt"; do
        [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; }
      done
    fi
  done
  echo "------------------------------------------"
  echo "luci.mk: $([ -f feeds/luci/luci.mk ] && echo '✓' || echo '✗ 缺失（luci app 无法解析）')"
  echo "tmp/.packageinfo 包总数: $(grep -c '^Package: ' tmp/.packageinfo 2>/dev/null || echo 0)"
  echo "=========================================="

  # 必装插件（config 里是 =y 的那几个）必须进索引，否则 defconfig 会静默剔除
  REQUIRED=""
  [ "$ADD_AIROHA_NPU" = "true" ] && REQUIRED="$REQUIRED luci-app-airoha-npu"
  if [ "$ADD_LUCI_APP" = "true" ]; then
    REQUIRED="$REQUIRED luci-app-natmode luci-app-pon-status"
  fi
  HARD_MISS=""
  for r in $REQUIRED; do
    grep -qx "Package: $r" tmp/.packageinfo 2>/dev/null || HARD_MISS="$HARD_MISS $r"
  done
  if [ -n "$HARD_MISS" ]; then
    echo "::error::以下必装插件未进入 tmp/.packageinfo，defconfig 会把 .config 里的 =y 静默剔除:$HARD_MISS"
    echo "  已索引缺失清单:$INDEX_MISS"
    exit 1
  fi
  [ -n "$INDEX_MISS" ] && echo "::warning::部分可选包未进入索引（不影响必装插件）:$INDEX_MISS"
else
  echo "未启用任何第三方插件"
fi

echo "🎉 diy-part1.sh 执行完毕"

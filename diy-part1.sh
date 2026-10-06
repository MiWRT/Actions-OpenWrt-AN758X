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
ADD_LUCKY=false        # luci-app-lucky（DDNS + socat）
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
#
# 所以需要 clone 整个仓库，再把子目录拷到 package/custom/。
# 目录名必须等于包名（luci.mk: PKG_NAME ?= $(notdir ${CURDIR})），
# 否则 config 里的 CONFIG_PACKAGE_xxx 符号对不上。
#
# ⚠️ 为什么不再用 CI 仓库自带的 packages/ 本地包：
#    上游 natmode 0.1.2 修了一个关键问题 ——
#    「LuCI 保存时 rpcd 暂存值 CLI 读不到」，导致点了保存但模式没应用
#    （commit: fix(natmode): apply button missing on PonWrt LuCI fork）。
#    修法是 apply 支持显式传参：apply <mode> [<fullcone6>] [<auto_offload>]
#    本地旧版是从 UCI 读值，在保存流程中会读到旧值。
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
if [ "$ADD_LUCKY" = "true" ]; then
  clone https://github.com/sirpdboy/luci-app-lucky "$PKG_DIR/luci-app-lucky" main
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

# =========================================================
# Wi-Fi 卸载 —— 下行 (wired -> WiFi) 与上行 (WiFi -> wired) 是两件事
#
#   方向以「连 WiFi 的终端」为准：
#     下行 = 终端接收：PPE/FOE → P3(GDM3) → WDMA → WED → PCIe → MT7916
#     上行 = 终端发出：WiFi rx ring → NPU 固件 BA 重排 → TDMA tx → PPE → 有线
#
#   这两条不是互斥的两条路线，而是**各管一个方向**，原厂两个都用：
#     - 上行是 NPU 固件自带的，不依赖 Linux flowtable（WED_DOWNLINK_PLAN.md
#       §三 的实机结论：「上行已经在跑」；固件里 tdma_tx_init 真实存在，
#       并打 INTR_TDMA_0 / INTR_PPE_WIFI_BUF_ID）
#     - 下行要 WED 来接。这也是我们一直没通的那个方向。
#
#   两者只在一个地方碰头：FOE IB2 的 PSE_PORT 是「PPE 往哪送」的字段，
#   只影响下行。上行是 WiFi → TDMA → PPE 入口，不走这个字段，所以
#   把出口改成 P3 不会动到上行。
#
#   both  默认，原厂配置：下行 WED + 上行 NPU
#         patches/kernel-wed/ 全部注入 + packages/airoha-wed 进源码树
#   npu   都不注入：下行也回到 P7（别人已跑通的那版，作为已知好基线）
#   wed   只装下行，并把 mt76 的 CONFIG_MT7915_NPU 摘掉 —— 用来隔离验证
#         「下行到底有没有通」，排除上行 NPU 的干扰
#
#   kernel-wed 里的补丁干什么：
#     960  wed/wdma 设备树节点（自带 airoha,wed-ops / attach-enable）
#     961  开 NET_VENDOR_MEDIATEK + NET_MEDIATEK_SOC
#          —— 不开的话 mtk_wed.h 里所有 helper 编译成空桩，mt7915
#             根本不会调 mtk_wed_device_attach()
#     962  让 NET_MEDIATEK_SOC_WED 接受 ARCH_AIROHA（原本只认 ARCH_MEDIATEK）
#     963  PPE 出口 P7(CDM4/TDMA) → P3(GDM3/WDMA) + IB2 补 PSE_QOS
#     964  HG5585F 把 wed/wdma 置 status="okay"
#
#   注意 963 与 WED 驱动必须同进同退：只改 force port 而 WED 没起来，
#   包会灌进 P3 没人取，PSE 共享缓冲耗尽，全芯片转发停摆
#   （WED_DOWNLINK_PLAN.md §四「必须注意的坑」记录过 11975 包积压）。
# =========================================================
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WIFI_OFFLOAD="${WIFI_OFFLOAD:-both}"

echo "=========================================="
echo "Wi-Fi 卸载: ${WIFI_OFFLOAD}  (下行/上行 = $( [ "$WIFI_OFFLOAD" = npu ] && echo 'NPU/NPU' || echo 'WED/NPU' ))"
echo "=========================================="

case "$WIFI_OFFLOAD" in
  both|wed)
    # wed 单点模式：把 mt76 的 NPU 开关摘掉，让下行成为唯一的硬件路径
    if [ "$WIFI_OFFLOAD" = "wed" ]; then
      MK="package/kernel/mt76/Makefile"
      if [ -f "$MK" ] && grep -q "CONFIG_MT7915_NPU" "$MK"; then
        sed -i '/CONFIG_MT7915_NPU/d' "$MK"
        echo "   ⚠ wed 单点：已从 $MK 摘掉 CONFIG_MT7915_NPU"
      fi
    fi
    # --- 1) SoC 侧 WED/WDMA 驱动包 ---
    if [ -d "$REPO_DIR/packages/airoha-wed" ]; then
      rm -rf "$PKG_DIR/airoha-wed"
      cp -r "$REPO_DIR/packages/airoha-wed" "$PKG_DIR/"
      echo "✅ 已拷贝本地包: airoha-wed (kmod-airoha-wed / kmod-airoha-wdma)"
    else
      echo "::error::缺本地包 $REPO_DIR/packages/airoha-wed，kmod-airoha-wed 会被 defconfig 剔除"
      exit 1
    fi

    # --- 2) 补丁 ---
    # 编号 96x 保证排在 ponwrt 自带的 950 之后（quilt 按文件名排序应用）。
    #
    # ⚠ 96x 里混着两类补丁，不能一股脑 cp 进 patches-6.18/：
    #   960/961/964 改的是 target/linux/airoha/{dts,an7581/config-6.18}，
    #   那是 OpenWrt 源码树；而 patches-6.18/ 是打在内核源码上的，里面根本没有
    #   target/linux/ 这个路径，quilt 会静默跳过 —— 表现就是"补丁注入成功"
    #   但 an7581-wed.dtsi 从来没被创建出来（CI 的 WED 设备树校验才发现）。
    #   962/963 才是真正的内核补丁（drivers/net/ethernet/...）。
    WED_PATCH_DIR="$REPO_DIR/patches/kernel-wed"
    if [ -d "$WED_PATCH_DIR" ]; then
      for p in "$WED_PATCH_DIR"/*.patch; do
        [ -e "$p" ] || continue
        if grep -qs '^+++ b/target/linux/' "$p"; then
          if git apply -p1 --ignore-whitespace "$p"; then
            echo "✅ 应用源码树补丁: $(basename "$p")"
          elif patch -p1 --forward --no-backup-if-mismatch < "$p"; then
            echo "✅ 应用源码树补丁(回退 patch): $(basename "$p")"
          else
            echo "::error::源码树补丁应用失败: $(basename "$p")"
            exit 1
          fi
        else
          cp "$p" target/linux/airoha/patches-6.18/
          echo "✅ 注入内核补丁: $(basename "$p")"
        fi
      done
    else
      echo "::error::缺补丁目录 $WED_PATCH_DIR"
      exit 1
    fi
    ;;
  npu)
    echo "   npu 路线：不注入 WED 补丁，下行出口保持 P7(CDM4/TDMA)"
    ;;
  *)
    echo "::error::未知 WIFI_OFFLOAD='$WIFI_OFFLOAD'（应为 both / wed / npu）"
    exit 1
    ;;
esac

echo "🎉 diy-part1.sh 执行完毕"

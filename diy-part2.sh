#!/bin/bash
# diy-part2.sh —— 在 .config 载入之后、make defconfig 之前执行
#
# 这里做两类事：
#   1) 用 ./scripts/config 强制开启中文语言包等软件包（随后由 make defconfig 展开）
#   2) 写 files/etc/uci-defaults/*，在设备首次启动时固化时区/LuCI 语言/硬件卸载
#
# 注意：不要只改 package/base-files/files/etc/config/system ——
# 首次启动时 config_generate 会重新生成 /etc/config/system 并把 timezone 写回 UTC，
# 所以时区必须在 uci-defaults 里改，或直接改 config_generate。

set -e
CFG=".config"
SCRIPTS_CFG="./scripts/config"


# ---------------------------------------------------------------
# 1. 时区 —— 改 config_generate 里的默认值（会被首次启动写入 /etc/config/system）
# ---------------------------------------------------------------
if [ -f package/base-files/files/bin/config_generate ]; then
    sed -i "s/timezone='UTC'/timezone='CST-8'/g" \
        package/base-files/files/bin/config_generate
    sed -i "s/zonename='UTC'/zonename='Asia\/Shanghai'/g" \
        package/base-files/files/bin/config_generate
    sed -i "s/option timezone 'UTC'/option timezone 'CST-8'/g" \
        package/base-files/files/bin/config_generate
fi
# 兜底：base-files 自带的 /etc/config/system
if [ -f package/base-files/files/etc/config/system ]; then
    sed -i "s#option timezone 'UTC'#option timezone 'CST-8'#" \
        package/base-files/files/etc/config/system
    sed -i "s#option zonename 'UTC'#option zonename 'Asia/Shanghai'#" \
        package/base-files/files/etc/config/system
fi

# ---------------------------------------------------------------
# 2. 强制开启中文语言包
#    defconfig 对不存在的包名会静默丢弃，这里开着不代表一定能编出来，
#    所以下面会校验 package 目录里到底有没有这些包。
# ---------------------------------------------------------------
I18N_PKGS="
luci-i18n-base-zh-cn
luci-i18n-firewall-zh-cn
luci-i18n-package-manager-zh-cn
luci-i18n-opkg-zh-cn
luci-i18n-pon-zh-cn
luci-i18n-iptv-zh-cn
luci-i18n-upnp-zh-cn
"

echo "===== 检查 luci-i18n 包在 feeds 中是否存在 ====="
FOUND_ANY=0
for p in $I18N_PKGS; do
    # feeds 装好后形如 feeds/luci/applications/luci-i18n-base-zh-cn 或 luci/.../luci-i18n-base-zh-cn
    if [ -d "feeds/luci/applications/$p" ] || [ -d "feeds/luci/modules/$p" ] \
       || [ -d "package/feeds/luci/$p" ] || [ -d "package/$p" ]; then
        echo "  [存在] $p"
        FOUND_ANY=1
    else
        echo "  [缺失] $p（feeds 里没有，开了也不会编出来）"
    fi
done

if [ "$FOUND_ANY" = "0" ]; then
    echo "::warning::feeds 中未找到任何 luci-i18n-*-zh-cn 包目录"
    echo "可能原因：luci feed 未安装 / 版本不含 i18n / 包名命名不同"
    echo "已存在的 luCI i18n 目录："
    find feeds package -maxdepth 4 -type d -name "luci-i18n*" 2>/dev/null | head -20 || true
fi

# 仍然尝试开启（存在的会生效，不存在的 defconfig 会静默丢弃）
for p in $I18N_PKGS; do
    "$SCRIPTS_CFG" --enable "CONFIG_PACKAGE_$p" 2>/dev/null || true
done

# 中文时区数据（zonename 需要 /usr/share/zoneinfo）
"$SCRIPTS_CFG" --enable CONFIG_PACKAGE_zoneinfo-asia 2>/dev/null || true

# ---------------------------------------------------------------
# 3. 光器件驱动 —— 防止 defconfig 把 =y 重置回 =m
# ---------------------------------------------------------------
DEVICE_LINE=$(grep -oE "^CONFIG_TARGET_DEVICE_airoha_an7581_DEVICE_[A-Za-z0-9_-]+=y" "$CFG" | head -1)
DEVICE_NAME=$(echo "$DEVICE_LINE" | sed 's/.*DEVICE_//; s/=y$//')
echo "===== 目标机型：$DEVICE_NAME ====="

case "$DEVICE_NAME" in
    fiberhome_*)
        echo "烽火机型 -> GN28L95 / UX3363 (paged-bosa)"
        "$SCRIPTS_CFG" --set-val CONFIG_PACKAGE_kmod-airoha-paged-bosa y
        "$SCRIPTS_CFG" --disable CONFIG_PACKAGE_kmod-airoha-en7572
        ;;
    *)
        echo "非烽火机型 -> EN7572"
        "$SCRIPTS_CFG" --set-val CONFIG_PACKAGE_kmod-airoha-en7572 y
        "$SCRIPTS_CFG" --disable CONFIG_PACKAGE_kmod-airoha-paged-bosa
        ;;
esac

# 其它易被重置为 =m 的模块，一并强制内置
for m in kmod-mt7915e kmod-mt7916-firmware kmod-phy-airoha-en8811h \
         airoha-en8811h-firmware kmod-fs-ext4 kmod-fs-exfat kmod-fs-vfat \
         kmod-usb3 kmod-usb-storage kmod-usb-storage-uas; do
    if grep -qE "^(# )?CONFIG_PACKAGE_${m}( is not set|=)" "$CFG"; then
        "$SCRIPTS_CFG" --set-val "CONFIG_PACKAGE_$m" y 2>/dev/null || true
    fi
done

# ---------------------------------------------------------------
# 4. 首次启动固化（uci-defaults）—— 时区 / LuCI 中文 / 硬件卸载
# ---------------------------------------------------------------
mkdir -p files/etc/uci-defaults

cat > files/etc/uci-defaults/99-pon-system <<'EOF'
# 主机名
uci -q set system.@system[0].hostname='PonWrt'
# 时区：CST-8（中国标准时间）
uci -q set system.@system[0].timezone='CST-8'
uci -q set system.@system[0].zonename='Asia/Shanghai'
uci -q commit system

# 硬件流卸载（AN7581 PPE / NPU）
uci -q set firewall.@defaults[0].flow_offloading=1
uci -q set firewall.@defaults[0].flow_offloading_hw=1
uci -q commit firewall
exit 0
EOF

cat > files/etc/uci-defaults/99-luci-lang <<'EOF'
# LuCI 默认简体中文
# 语言代码是 zh_cn（下划线），不是 zh-cn
uci -q set luci.main=core
uci -q set luci.main.lang='zh_cn'
uci -q set luci.main.mediaurlbase='/luci-static/argon'
uci -q commit luci
exit 0
EOF

# ---------------------------------------------------------------
# 5. 输出核对
# ---------------------------------------------------------------
echo "===== 中文包开关状态 ====="
grep -E "^CONFIG_PACKAGE_luci-i18n.*zh-cn" "$CFG" || echo "::warning::配置中没有任何 zh-cn 包"
echo "===== 时区相关 ====="
grep -E "^CONFIG_PACKAGE_zoneinfo" "$CFG" || echo "::warning::未开启 zoneinfo"
echo "===== 光器件驱动 ====="
grep -E "^CONFIG_PACKAGE_kmod-airoha-(en7572|paged-bosa)" "$CFG" || true

echo "[diy-part2] 完成"

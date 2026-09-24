#!/bin/bash
# diy-part2.sh —— 在 .config 载入之后、make defconfig 之前执行
# 只做与机型无关的通用调整，机型与 PON 组件的开关全部由 configs/*.config 决定。
set -e

CFG=".config"

# 主机名
if [ -f package/base-files/files/bin/config_generate ]; then
    sed -i 's/ImmortalWrt/PonWrt/g' package/base-files/files/bin/config_generate
fi

# 时区
if [ -f package/base-files/files/etc/config/system ]; then
    sed -i "s#option timezone 'UTC'#option timezone 'CST-8'#" package/base-files/files/etc/config/system
    sed -i "s#option zonename 'UTC'#option zonename 'Asia/Shanghai'#" package/base-files/files/etc/config/system
fi

# 默认开启硬件流卸载（AN7581 PPE / NPU）
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-pon-offload <<'EOF'
uci -q set firewall.@defaults[0].flow_offloading=1
uci -q set firewall.@defaults[0].flow_offloading_hw=1
uci -q commit firewall
exit 0
EOF

# LuCI 默认简体中文
# 说明：装了 luci-i18n-*-zh-cn 只是"提供中文语言文件"，LuCI 默认 lang 是 auto/en，
# 不会自动切中文。首次登录的语言选择页若点了 English，就会被写成 en 并一直生效。
# 这里在 uci-defaults 阶段强制写入，让固件刷完就是中文。
cat > files/etc/uci-defaults/99-luci-lang <<'EOF'
# luci.main section 不存在则先创建（uci set 对缺失 section 会自动建 core 类型）
[ -n "$(uci -q get luci.main)" ] || uci -q set luci.main=core
uci -q set luci.main.lang='zh_cn'
uci -q set luci.main.mediaurlbase='/luci-static/argon'
uci -q commit luci
exit 0
EOF

echo "[diy-part2] 完成"

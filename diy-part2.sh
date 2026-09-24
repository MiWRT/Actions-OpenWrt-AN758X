#!/bin/bash
# ================================================================
# diy-part2.sh —— 加载 .config 之后执行
# 运行目录: ponwrt 源码根目录
# 职责: 系统默认参数 / 网络优化 / ccache / 版本信息
# 注意: 机型裁剪由 workflow 的 Apply device profile 步骤完成，这里不要动 TARGET_DEVICE
# ================================================================

echo "=========================================="
echo "执行自定义脚本 (diy-part2.sh)"
echo "=========================================="

# ---------------------------------------------------------
# 1. 系统默认参数（按需修改）
# ---------------------------------------------------------
HOSTNAME="PonWrt"          # 主机名
LAN_IP=""                  # 留空=保持源码默认(192.168.1.1)；填入如 192.168.30.1 则覆盖
TIMEZONE="CST-8"
ZONE_NAME="Asia/Shanghai"

# 主机名 / 时区
sed -i "s/option hostname.*/option hostname '${HOSTNAME}'/" package/base-files/files/bin/config_generate
sed -i "s/option timezone.*/option timezone '${TIMEZONE}'/" package/base-files/files/bin/config_generate
sed -i "s/option zonename.*/option zonename '${ZONE_NAME}'/" package/base-files/files/bin/config_generate

# LAN IP（可选）
if [ -n "$LAN_IP" ]; then
  sed -i "s/192\.168\.1\.1/${LAN_IP}/g" package/base-files/files/bin/config_generate
  echo "✅ 默认 LAN IP -> ${LAN_IP}"
fi

# 发行版标识
sed -i "s/DISTRIB_DESCRIPTION=.*/DISTRIB_DESCRIPTION='PonWrt CI Build'/" package/base-files/files/etc/openwrt_release 2>/dev/null
sed -i "s/DISTRIB_REVISION=.*/DISTRIB_REVISION='R$(date +%Y%m%d)'/" package/base-files/files/etc/openwrt_release 2>/dev/null

# ---------------------------------------------------------
# 2. 开启 ccache（配合 workflow 的 ccache 缓存步骤）
# ---------------------------------------------------------
if [ "$USE_CCACHE" = "true" ]; then
  sed -i '/CONFIG_CCACHE/d' .config
  sed -i '/CONFIG_CCACHE_DIR/d' .config
  cat >> .config <<'EOF'
CONFIG_DEVEL=y
CONFIG_CCACHE=y
CONFIG_CCACHE_DIR=".ccache"
EOF
  mkdir -p .ccache
  echo "✅ ccache 已开启"
fi

# ---------------------------------------------------------
# 3. 网络参数优化 (写入 files/，自动进 rootfs)
# ---------------------------------------------------------
mkdir -p files/etc/sysctl.d
cat > files/etc/sysctl.d/99-ponwrt.conf <<'SYSCTL'
# Conntrack
net.netfilter.nf_conntrack_max=32768
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_udp_timeout=60
net.netfilter.nf_conntrack_udp_timeout_stream=120

# TCP
net.core.netdev_max_backlog=2048
net.core.somaxconn=2048
net.ipv4.tcp_max_syn_backlog=2048
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=600

# 缓冲区
net.core.rmem_max=4194304
net.core.wmem_max=4194304
net.ipv4.tcp_rmem=4096 131072 4194304
net.ipv4.tcp_wmem=4096 65536 4194304
SYSCTL
echo "✅ 网络优化参数已写入"

# ---------------------------------------------------------
# 4. 收尾提示：PON 校准数据恢复路径
# ---------------------------------------------------------
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-pon-note <<'NOTE'
#!/bin/sh
# 刷机后请通过 U-Boot Web 或 LuCI: 网络 -> PON -> Configuration
# 恢复 factory / dsd / reservearea / bosa / ri 校准与身份数据
exit 0
NOTE
chmod +x files/etc/uci-defaults/99-pon-note

echo "🎉 diy-part2.sh 执行完毕"

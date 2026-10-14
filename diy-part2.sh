#!/bin/bash
# ================================================================
# diy-part2.sh —— 默认值定制（在 .config 加载之后运行）
# 运行目录: ponwrt 源码根目录
#
#   1) 默认时区改成中国（Asia/Shanghai, CST-8）
#   2) WiFi：2.4G SSID / 信道 3、5G SSID / 国家码 CN / 信道 40 / 频宽 160MHz
#   3) 概览页「CPU 使用率（%）」行：显示 USR/SYS + 每个核心的明细
#   4) 固件版本后追加「作者 + 构建时间」
#
# ================================================================

set -euo pipefail

echo "=========================================="
echo "默认值定制：时区 + 5G WiFi (diy-part2.sh)"
echo "=========================================="

# =============================================================
# 可配置：5G 无线参数
# 如需改动，直接改这里即可（编译期常量，会写进 uci-defaults 脚本）
# =============================================================
WIFI_5G_COUNTRY="${WIFI_5G_COUNTRY:-CN}"       # 国家代码（CN = 中国）
WIFI_2G_SSID="${WIFI_2G_SSID:-Moto}"            # 2.4G 默认 SSID
WIFI_2G_KEY="${WIFI_2G_KEY:-arzin1122}"         # 2.4G 默认密码
WIFI_2G_CHANNEL="${WIFI_2G_CHANNEL:-3}"         # 2.4G 默认信道
WIFI_5G_SSID="${WIFI_5G_SSID:-Moto_5G}"         # 5G 默认 SSID
WIFI_5G_KEY="${WIFI_5G_KEY:-arzin1122}"         # 5G 默认密码
WIFI_5G_CHANNEL="${WIFI_5G_CHANNEL:-40}"      # 5G 默认信道
WIFI_5G_HTMODE="${WIFI_5G_HTMODE:-HE160}"      # 160MHz（WiFi6）；回落 HE80
WIFI_5G_FALLBACK="${WIFI_5G_FALLBACK:-HE80}"   # 硬件不支持 160MHz 时的回落值

# 作者名：由 workflow 的 env.FW_AUTHOR 传入（workflow 里改为 ${{ github.repository_owner }} 即可直接读 GitHub 用户名）
# 这里只做回落：workflow 没传时用 qwe
FW_AUTHOR="${FW_AUTHOR:-qwe}"
FW_BUILD_TIME="${FW_BUILD_TIME:-}"
FW_DESC_SUFFIX="${FW_DESC_SUFFIX:-}" 

echo "配置：2.4G ssid=$WIFI_2G_SSID channel=$WIFI_2G_CHANNEL"
echo "配置：5G ssid=$WIFI_5G_SSID country=$WIFI_5G_COUNTRY channel=$WIFI_5G_CHANNEL htmode=$WIFI_5G_HTMODE fallback=$WIFI_5G_FALLBACK"
echo "配置：FW_AUTHOR=$FW_AUTHOR (由 workflow env.FW_AUTHOR 传入)"

# ---------------------------------------------------------
# 1. 修改 config_generate 的默认值（首次开机生成的 /etc/config/system）
# ---------------------------------------------------------
CFG="package/base-files/files/bin/config_generate"

if [ -f "$CFG" ]; then
  # 兼容 @system[-1]（旧）与 @system[0]（OpenWrt 21+）
  sed -i "s/option timezone.*/option timezone 'CST-8'/" "$CFG"
  sed -i "s/option zonename.*/option zonename 'Asia\/Shanghai'/" "$CFG"
  echo "✅ config_generate 默认时区 -> CST-8 / Asia/Shanghai"
else
  echo "::warning::未找到 $CFG，跳过默认值修改"
fi

# ---------------------------------------------------------
# 2. uci-defaults：即使保留了旧配置也强制刷成中国时区
# ---------------------------------------------------------
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-timezone-cn <<'EOF'
#!/bin/sh
uci -q batch <<'UCI'
set system.@system[0].zonename='Asia/Shanghai'
set system.@system[0].timezone='CST-8'
commit system
UCI
exit 0
EOF
chmod +x files/etc/uci-defaults/99-timezone-cn
echo "✅ uci-defaults 时区脚本已写入"

# ---------------------------------------------------------
# 3. 补上亚洲时区数据库包（LuCI 显示与时区切换需要）
# ---------------------------------------------------------
if [ -f .config ]; then
  sed -i '/^CONFIG_PACKAGE_zoneinfo-asia=/d; /^# CONFIG_PACKAGE_zoneinfo-asia is not set/d' .config
  echo "CONFIG_PACKAGE_zoneinfo-asia=y    # 亚洲时区数据库（中国时区需要）" >> .config
  echo "✅ zoneinfo-asia 已加入 .config"
fi

# ---------------------------------------------------------
# 4. WiFi：2.4G SSID / 信道 3、5G 国家码 CN / 信道 40 / 频宽 160MHz
#
#    分两层落地：
#      a) 编译期：改无线 detect 脚本的默认值（best effort，找不到就跳过）
#      b) 运行期：uci-defaults 首启强制刷（主要手段，与保留配置升级都生效）
#
#    说明：不同版本 detect 脚本路径不同（有的叫 mac80211.sh / mac80211.uc），
#    且 uci-defaults 执行时 /etc/config/wireless 可能尚未生成，
#    故 uci-defaults 里自带「未生成就先生成」的逻辑。
# ---------------------------------------------------------

# ---- 4a. 编译期：改 detect 脚本默认值（best effort） ----
DETECT_SCRIPT=""
for cand in \
  "package/kernel/mac80211/files/lib/wifi/mac80211.sh" \
  "package/kernel/mac80211/files/lib/wifi/mac80211.uc" \
  "package/network/services/hostapd/files/lib/wifi/mac80211.sh"; do
  [ -f "$cand" ] && { DETECT_SCRIPT="$cand"; break; }
done

if [ -n "$DETECT_SCRIPT" ]; then
  # 5G（11a / band 5g）的默认信道改成 40
  sed -i "s/option channel '36'/option channel '40'/g" "$DETECT_SCRIPT"
  sed -i "s/option channel='36'/option channel='40'/g" "$DETECT_SCRIPT"
  sed -i "s/option channel 'auto'/option channel '40'/g" "$DETECT_SCRIPT"
  sed -i "s/option channel='auto'/option channel='40'/g" "$DETECT_SCRIPT"
  echo "✅ detect 脚本默认信道 -> 40 ($DETECT_SCRIPT)"
else
  echo "::warning::未找到无线 detect 脚本，跳过编译期默认值修改（由 uci-defaults 兜底）"
fi

# ---- 4b. 运行期：uci-defaults 首启强制刷 ----
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/96-wifi-5g-cn <<UCEOF
#!/bin/sh
# 5G WiFi 默认值：国家码 CN、信道 40、频宽 160MHz
# 由 diy-part2.sh 生成（编译期常量注入）

COUNTRY='$WIFI_5G_COUNTRY'
CHANNEL='$WIFI_5G_CHANNEL'
HTMODE='$WIFI_5G_HTMODE'
FALLBACK='$WIFI_5G_FALLBACK'
SSID='$WIFI_5G_SSID'
KEY='$WIFI_5G_KEY'

log() { logger -t wifi-5g "\$@"; }

# uci-defaults 可能在 wifi config 之前执行 —— 没生成就先生成
if [ ! -f /etc/config/wireless ]; then
	command -v wifi >/dev/null 2>&1 && wifi config >/dev/null 2>&1
fi
[ -f /etc/config/wireless ] || { log "未找到 /etc/config/wireless，跳过"; exit 0; }

# 检测该 phy 是否支持 160MHz（兼容 "160 MHz" 与 "80+80 MHz" 两种表述）
support_160() {
	local phy="\$1"
	[ -z "\$phy" ] && return 1
	command -v iw >/dev/null 2>&1 || return 1
	iw phy "\$phy" info 2>/dev/null | grep -qE '160 MHz|80\+80 MHz' || return 1
	return 0
}

# 给指定 radio 找/建 AP iface 并设 SSID + 密码（WPA2-PSK）
set_iface() {
	local dev="\$1" ssid="\$2" key="\$3"
	local sec found=""
	for sec in \$(uci -q show wireless | sed -n 's/^wireless\\.\\([A-Za-z0-9_-]*\\)=wifi-iface\$/\\1/p'); do
		[ "\$(uci -q get wireless.\$sec.device 2>/dev/null)" = "\$dev" ] || continue
		[ "\$(uci -q get wireless.\$sec.mode 2>/dev/null)" = "ap" ] || continue
		found="\$sec"
		break
	done
	if [ -z "\$found" ]; then
		found="\$(uci -q add wireless wifi-iface)"
		[ -n "\$found" ] || return 1
		uci -q set wireless.\$found.device="\$dev"
		uci -q set wireless.\$found.network='lan'
		uci -q set wireless.\$found.mode='ap'
	fi
	uci -q set wireless.\$found.ssid="\$ssid"
	uci -q set wireless.\$found.encryption='psk2'
	uci -q set wireless.\$found.key="\$key"
	log "\$dev：SSID=\$ssid（iface=\$found）"
}

changed=0
for dev in \$(uci -q show wireless | sed -n 's/^wireless\.\([A-Za-z0-9_-]*\)=wifi-device\$/\1/p'); do
	band="\$(uci -q get wireless.\$dev.band 2>/dev/null)"
	hwmode="\$(uci -q get wireless.\$dev.hwmode 2>/dev/null)"

	# 只处理 5G：新版用 band='5g'，旧版用 hwmode='11a'
	is5g=0
	[ "\$band" = "5g" ] && is5g=1
	[ -z "\$band" ] && [ "\$hwmode" = "11a" ] && is5g=1
	[ "\$is5g" = "0" ] && continue

	# 频宽：确认不支持 160MHz 才回落
	# 取不到 phy 名时不检测（保持 HTMODE）—— 避免无 phy 选项的 radio 被误判回落
	ht="\$HTMODE"
	phy="\$(uci -q get wireless.\$dev.phy 2>/dev/null)"
	if [ -n "\$phy" ] && ! support_160 "\$phy"; then
		ht="\$FALLBACK"
		log "\$dev：未检测到 160MHz 能力，回落为 \$ht"
	fi

	uci -q set wireless.\$dev.country="\$COUNTRY"
	uci -q set wireless.\$dev.country_ie='1'
	uci -q set wireless.\$dev.channel="\$CHANNEL"
	uci -q set wireless.\$dev.htmode="\$ht"

	set_iface "\$dev" "\$SSID" "\$KEY"

	log "\$dev：country=\$COUNTRY channel=\$CHANNEL htmode=\$ht"
	changed=1
done

if [ "\$changed" = "1" ]; then
	uci -q commit wireless
	# 重载而非重启：避免首启期间无线中断后不可恢复
	command -v wifi >/dev/null 2>&1 && wifi reload >/dev/null 2>&1 || true
	log "已提交 wireless 配置"
else
	log "未找到 5G radio，未做任何修改"
fi

exit 0
UCEOF
chmod +x files/etc/uci-defaults/96-wifi-5g-cn
echo "✅ uci-defaults 5G WiFi 脚本已写入（country=$WIFI_5G_COUNTRY channel=$WIFI_5G_CHANNEL htmode=$WIFI_5G_HTMODE）"

# ---- 4c. 运行期：2.4G uci-defaults 首启强制刷 ----
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/97-wifi-2g <<UCEOF
#!/bin/sh
# 2.4G WiFi 默认值：SSID + 密码 + 信道 3
# 由 diy-part2.sh 生成（编译期常量注入）

SSID='$WIFI_2G_SSID'
KEY='$WIFI_2G_KEY'
CHANNEL='$WIFI_2G_CHANNEL'
COUNTRY='$WIFI_5G_COUNTRY'

log() { logger -t wifi-2g "\$@"; }

if [ ! -f /etc/config/wireless ]; then
	command -v wifi >/dev/null 2>&1 && wifi config >/dev/null 2>&1
fi
[ -f /etc/config/wireless ] || { log "未找到 /etc/config/wireless，跳过"; exit 0; }

# 给指定 radio 找/建 AP iface 并设 SSID + 密码（WPA2-PSK）
set_iface() {
	local dev="\$1" ssid="\$2" key="\$3"
	local sec found=""
	for sec in \$(uci -q show wireless | sed -n 's/^wireless\\.\\([A-Za-z0-9_-]*\\)=wifi-iface\$/\\1/p'); do
		[ "\$(uci -q get wireless.\$sec.device 2>/dev/null)" = "\$dev" ] || continue
		[ "\$(uci -q get wireless.\$sec.mode 2>/dev/null)" = "ap" ] || continue
		found="\$sec"
		break
	done
	if [ -z "\$found" ]; then
		found="\$(uci -q add wireless wifi-iface)"
		[ -n "\$found" ] || return 1
		uci -q set wireless.\$found.device="\$dev"
		uci -q set wireless.\$found.network='lan'
		uci -q set wireless.\$found.mode='ap'
	fi
	uci -q set wireless.\$found.ssid="\$ssid"
	uci -q set wireless.\$found.encryption='psk2'
	uci -q set wireless.\$found.key="\$key"
	log "\$dev：SSID=\$ssid（iface=\$found）"
}

changed=0
for dev in \$(uci -q show wireless | sed -n 's/^wireless\\.\\([A-Za-z0-9_-]*\\)=wifi-device\$/\\1/p'); do
	band="\$(uci -q get wireless.\$dev.band 2>/dev/null)"
	hwmode="\$(uci -q get wireless.\$dev.hwmode 2>/dev/null)"

	# 只处理 2.4G：新版用 band='2g'，旧版用 hwmode='11g'
	is2g=0
	[ "\$band" = "2g" ] && is2g=1
	[ -z "\$band" ] && [ "\$hwmode" = "11g" ] && is2g=1
	[ "\$is2g" = "0" ] && continue

	uci -q set wireless.\$dev.country="\$COUNTRY"
	uci -q set wireless.\$dev.country_ie='1'
	uci -q set wireless.\$dev.channel="\$CHANNEL"

	set_iface "\$dev" "\$SSID" "\$KEY"
	log "\$dev：country=\$COUNTRY channel=\$CHANNEL"
	changed=1
done

if [ "\$changed" = "1" ]; then
	uci -q commit wireless
	command -v wifi >/dev/null 2>&1 && wifi reload >/dev/null 2>&1 || true
	log "已提交 wireless 配置"
else
	log "未找到 2.4G radio，未做任何修改"
fi

exit 0
UCEOF
chmod +x files/etc/uci-defaults/97-wifi-2g
echo "✅ uci-defaults 2.4G WiFi 脚本已写入（ssid=$WIFI_2G_SSID channel=$WIFI_2G_CHANNEL）"

# ---- 4c. 确保 hostapd 支持 160MHz / 11ax ----
# wpad-openssl = 完整版 hostapd，支持 HE160；
# 若用的是 wpad-basic / hostapd-basic（精简版），160MHz 可能不生效。
if [ -f .config ]; then
  if grep -qE "^CONFIG_PACKAGE_(wpad-basic|hostapd-basic)=y" .config; then
    echo "::warning::检测到精简版 wpad/hostapd-basic，160MHz 可能不支持"
  fi
  # 无线工具：uci-defaults 里的能力检测需要 iw
  if ! grep -q "^CONFIG_PACKAGE_iw=y" .config; then
    sed -i '/^CONFIG_PACKAGE_iw=/d; /^# CONFIG_PACKAGE_iw is not set/d' .config
    echo "CONFIG_PACKAGE_iw=y                       # 无线命令行工具（160MHz 能力检测需要）" >> .config
    echo "✅ iw 已加入 .config"
  fi
fi

# ---------------------------------------------------------
# 4d. 全局网络选项默认值：IPv6 ULA 前缀清空、数据包引导禁用
#     对应 LuCI「网络 → 接口 → 全局网络选项」页。
#     用 uci-defaults 在首启时刷（config_generate 生成的默认值会被覆盖）。
# ---------------------------------------------------------
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/98-network-globals <<'EOF'
#!/bin/sh
# 全局网络选项默认值：清空 IPv6 ULA 前缀、禁用数据包引导
# 由 diy-part2.sh 生成

# 确保 globals 段存在（缺失时新建）
uci -q get network.globals >/dev/null 2>&1 || uci -q set network.globals=globals

# IPv6 ULA 前缀：清空（不设置）
uci -q delete network.globals.ula_prefix

# 数据包引导：禁用
uci -q set network.globals.packet_steering='0'

uci -q commit network
exit 0
EOF
chmod +x files/etc/uci-defaults/98-network-globals
echo "✅ uci-defaults 全局网络选项脚本已写入（ULA 前缀清空、数据包引导禁用）"

# ---------------------------------------------------------
# 4e. DNS 默认值：DNS 重定向关闭（不劫持 DNS）
#     对应 LuCI「网络 → DNS → 常规」页的「DNS 重定向」选项。
#     固件默认 dhcp.conf 里是 dns_redirect=1（开启，即 DNS 劫持），
#     这里用 uci-defaults 在首启时改为 0（关闭）。
# ---------------------------------------------------------
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/98-dns-defaults <<'EOF'
#!/bin/sh
# DNS 默认值：DNS 重定向关闭（不劫持 DNS）
# 由 diy-part2.sh 生成
uci -q set dhcp.@dnsmasq[0].dns_redirect='0'
uci -q commit dhcp
exit 0
EOF
chmod +x files/etc/uci-defaults/98-dns-defaults
echo "✅ uci-defaults DNS 默认脚本已写入（DNS 重定向关闭）"

# ---------------------------------------------------------
# 5. 概览页「CPU 使用率（%）」行：显示 USR/SYS + 每核明细
#
#    ImmortalWrt 的 luci 把这一行的值写成
#      luci.getCPUUsage → popen("top -n1 | awk '/^CPU/ {printf(\"%d%\", 100 - $8)}'")
#    只有一个总占用率。这里把它改指到 files/sbin/cpuusage（rootfs 覆盖，
#    已由 workflow 第 6 步拷进源码树的 files/），前端 10_system.js 与 ACL
#    都不用动。
#
#    脚本负责判断、打补丁与自检，找不到目标只 warning 不中断编译 ——
#    这是纯显示层的东西，不该让它把一次几小时的构建搞挂。
# ---------------------------------------------------------
PATCH_CPUUSAGE="$(dirname "$0")/scripts/patch-luci-cpuusage.sh"
if [ -f "$PATCH_CPUUSAGE" ]; then
  PONWRT_DIR=. bash "$PATCH_CPUUSAGE" || true
else
  echo "::warning::未找到 $PATCH_CPUUSAGE，跳过概览页 CPU 使用率行定制"
fi

[ -z "$FW_BUILD_TIME" ] && FW_BUILD_TIME="$(TZ="${TZ:-Asia/Shanghai}" date '+%Y-%m-%d %H:%M')"

VER_CODE="$(sed -n 's/^CONFIG_VERSION_CODE="\(.*\)"$/\1/p' .config 2>/dev/null || true)"
if [ -n "$VER_CODE" ]; then
  DESC_BODY='%D %V %C'
else
  DESC_BODY='%D %V'
fi
[ -z "$FW_DESC_SUFFIX" ] && FW_DESC_SUFFIX="· ${FW_AUTHOR} · ${FW_BUILD_TIME}"

RELEASE_TPL="package/base-files/files/etc/openwrt_release"
OSREL_TPL="package/base-files/files/usr/lib/os-release"

# 用 perl + 环境变量传替换文本：作者名/后缀里带 / | # & 都不会搞坏语法
# （直接 sed "s|...|${FW_DESC_SUFFIX}|" 遇到这些字符会炸）
FW_DESC_LINE="DISTRIB_DESCRIPTION='${DESC_BODY} ${FW_DESC_SUFFIX}'"
OSREL_LINE="OPENWRT_RELEASE=\"${DESC_BODY} ${FW_DESC_SUFFIX}\""
export FW_DESC_LINE OSREL_LINE

if [ -f "$RELEASE_TPL" ]; then
  # 只替换 DISTRIB_DESCRIPTION 行，不动 DISTRIB_ID / DISTRIB_RELEASE 等其它行
  perl -i -pe 's/^DISTRIB_DESCRIPTION=.*/$ENV{FW_DESC_LINE}/' "$RELEASE_TPL"
  echo "✅ 固件版本模板 -> $FW_DESC_LINE"
else
  echo "::warning::未找到 $RELEASE_TPL，固件版本不会带构建信息"
fi

# os-release 同步（部分工具/LuCI 版本读它；%B 只是 SOURCE_DATE_EPOCH 时间戳，不好看）
if [ -f "$OSREL_TPL" ]; then
  perl -i -pe 's/^OPENWRT_RELEASE=.*/$ENV{OSREL_LINE}/' "$OSREL_TPL"
  echo "✅ os-release 同步 -> $OSREL_LINE"
fi

echo "🎉 diy-part2.sh 执行完毕 (author=$FW_AUTHOR)"

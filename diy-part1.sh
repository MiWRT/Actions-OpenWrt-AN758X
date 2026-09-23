#!/bin/bash
# diy-part1.sh —— 在 ./scripts/feeds update 之前执行
# ponwrt 的 feeds.conf.default 一般已含 pon_drivers / pon_userspace，
# 这里做幂等兜底：缺哪个补哪个，已有则跳过。

FEED_FILE="feeds.conf.default"
[ -f feeds.conf ] && FEED_FILE="feeds.conf"

add_feed() {
    local name="$1" line="$2"
    if grep -qE "^src-git[[:space:]]+${name}[[:space:]]" "$FEED_FILE" 2>/dev/null; then
        echo "[diy-part1] ${name} 已存在，跳过"
    else
        echo "$line" >> "$FEED_FILE"
        echo "[diy-part1] 已添加 ${name}"
    fi
}

add_feed "pon_drivers"   "src-git pon_drivers https://github.com/pbs05/openwrt-pon-drivers.git"
add_feed "pon_userspace" "src-git pon_userspace https://github.com/pbs05/openwrt-pon-userspace.git"

echo "[diy-part1] 当前 feeds 配置："
cat "$FEED_FILE"

#!/usr/bin/env bash
# ==================================================================
# sync-mt76.sh —— 在编译前把 mt76 驱动包拉取并覆盖进 ponwrt 源码树
#
# 运行目录：ponwrt 源码根目录（即 $BUILD_ROOT/openwrt）
#
# 覆盖目标：package/kernel/mt76/
#   ├── Makefile                          ← 定义了源码版本 + NPU 编译开关
#   └── patches/1xx-*.patch               ← 驱动补丁（在解压源码后自动 quilt 应用）
#
# ------------------------------------------------------------------
# 为什么必须是「整目录替换」而不是「只拷补丁」
# ------------------------------------------------------------------
# 1) Makefile 里的 PKG_SOURCE_VERSION 决定拉哪一版 mt76 源码，
#    补丁是依托具体源码写的，两者必须成套，拆开来极易 quilt 打不上；
# 2) 113 号补丁新增了 mt7915/npu.c 与 CONFIG_MT7915_NPU，
#    而 npu.c 只有在 Makefile 打开 CONFIG_MT7915_NPU 时才会被编进去。
#    只拷补丁不改 Makefile → init.c 里的 mt7915_npu_hw_init() 链接不到符号，
#    直接编不过。所以「Makefile + 补丁」是一套，必须一起换。
#
# ------------------------------------------------------------------
# 三种来源（由 MT76_SOURCE 决定）
# ------------------------------------------------------------------
#   vendored  用本仓库 mt76/ 目录里随仓库携带的文件（默认，最稳，不依赖网络）
#   remote    从 GitHub 现拉（MT76_REPO / MT76_REF / MT76_SUBDIR）
#             拉取失败时按 MT76_FALLBACK 决定是否回退到 vendored
#   none      不动源码里的 mt76，用 ponwrt 自带版本
#
# ------------------------------------------------------------------
# 用法（全部走环境变量，便于 GitHub Actions 直接传）
# ------------------------------------------------------------------
#   MT76_SOURCE=vendored CI_REPO=/home/runner/work/x/x ./scripts/sync-mt76.sh
#   MT76_SOURCE=remote MT76_REPO=qwe3017/ponwrt MT76_REF=master \
#     MT76_SUBDIR=package/kernel/mt76 MT76_FALLBACK=true ./scripts/sync-mt76.sh
#
# ⚠️ 代理说明：GitHub Actions runner 能直连 GitHub，这里**不使用** gh-proxy。
#    只有本机手动下载时才需要代理 —— 见 scripts/fetch-mt76-local.sh。
# ==================================================================
set -euo pipefail

# ---------------------------- 配置 ----------------------------
MT76_SOURCE="${MT76_SOURCE:-vendored}"                 # vendored | remote | none
MT76_REPO="${MT76_REPO:-qwe3017/ponwrt}"               # remote 模式：owner/repo
MT76_REF="${MT76_REF:-master}"                         # remote 模式：分支 / tag / commit sha
MT76_SUBDIR="${MT76_SUBDIR:-package/kernel/mt76}"      # remote 模式：仓库内路径
MT76_FALLBACK="${MT76_FALLBACK:-true}"                 # remote 拉取/校验失败是否回退 vendored
MT76_GIT_HOST="${MT76_GIT_HOST:-https://github.com}"   # remote 模式：git 主机
# strict=true 要求「带 NPU 的 mt76」（Makefile 有 CONFIG_MT7915_NPU + 三个补丁）；
# 置 false 则只要能拿到 Makefile 与 patches 目录就放行（会有 warning）。
MT76_STRICT="${MT76_STRICT:-true}"

# CI 仓库根目录（vendored 模式从这里取 mt76/）。
# GitHub Actions 里由 workflow 显式传入 $GITHUB_WORKSPACE；本地跑时回退到脚本上级目录。
if [ -z "${CI_REPO:-}" ]; then
  CI_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# 期望的关键特征（用于校验覆盖到位的确实是「带 NPU 的 mt76」）
NEED_PATCHES=(
  "100-wifi-mt76-mt7996-Use-tx_power-from-default-fw-if-EEP.patch"
  "110-mt7915-add-mt7916-cal-free-merge.patch"
  "113-mt7915-npu-vendor-rewrite.patch"
)
NEED_MAKEFILE_MARKERS=("CONFIG_MT76_NPU" "CONFIG_MT7915_NPU")

SRC_DIR=""          # 实际使用的来源目录
WORK="$(pwd)/.mt76-sync"
DEST="package/kernel/mt76"

log()  { echo "==> $*"; }
warn() { echo "::warning::$*"; }
err()  { echo "::error::$*"; }

# ------------------------------------------------------------------
# 校验一个来源目录是否是「可用的、带 NPU 的 mt76」
#   返回 0 = 可用；返回 1 = 不合格
#
#   为什么要单独校验而不是拷完再说：上游 qwe3017/ponwrt 的 mt76 只有
#   100/110 两个补丁、Makefile 里也没有 CONFIG_MT7915_NPU（它的
#   CONFIG_MT76_NPU 是给 MT7996 用的）。若 remote 拉到上游版本却照拷不误，
#   MT7916 的 NPU 卸载就悄悄没了 —— 这种问题编完固件才看得出来。
#   所以先在来源目录上判定，不合格就换来源，绝不落进源码树。
# ------------------------------------------------------------------
verify_src() {
  local d="$1" rc=0

  [ -f "$d/Makefile" ] || { echo "    ✗ $d/Makefile 不存在"; return 1; }

  if [ "$MT76_STRICT" = "true" ]; then
    for m in "${NEED_MAKEFILE_MARKERS[@]}"; do
      grep -q "$m" "$d/Makefile" \
        && echo "    ✓ Makefile 含 $m" \
        || { echo "    ✗ Makefile 缺少 $m"; rc=1; }
    done
    for p in "${NEED_PATCHES[@]}"; do
      [ -f "$d/patches/$p" ] \
        && echo "    ✓ $p" \
        || { echo "    ✗ 缺少 $p"; rc=1; }
    done
  else
    [ -d "$d/patches" ] \
      && echo "    ✓ patches/ 存在（$(ls -1 "$d/patches" 2>/dev/null | wc -l) 个）" \
      || { echo "    ✗ patches/ 不存在"; rc=1; }
  fi

  return $rc
}

echo "=========================================="
echo "同步 mt76 驱动包 (source=${MT76_SOURCE})"
echo "=========================================="

# ------------------------------------------------------------------
# 0) none：直接跳过
# ------------------------------------------------------------------
if [ "$MT76_SOURCE" = "none" ]; then
  warn "MT76_SOURCE=none，跳过覆盖，使用 ponwrt 自带 mt76"
  echo "MT76_MODE=none" > "$WORK.env" 2>/dev/null || true
  exit 0
fi

[ -d "$DEST" ] || { err "找不到 $DEST，确认当前目录是 ponwrt 源码根目录（当前：$(pwd)）"; exit 1; }

# ------------------------------------------------------------------
# 1) 准备来源目录
# ------------------------------------------------------------------
prepare_vendored() {
  local v="$CI_REPO/mt76"
  [ -f "$v/Makefile" ] || return 1
  SRC_DIR="$v"
  return 0
}

prepare_remote() {
  rm -rf "$WORK"; mkdir -p "$WORK"
  local repo_url="${MT76_GIT_HOST}/${MT76_REPO}"
  log "从 ${repo_url} (ref=${MT76_REF}) 拉取 ${MT76_SUBDIR}"

  # 只拉目标子目录，避免整仓 20MB+ 克隆
  git -C "$WORK" init -q
  git -C "$WORK" remote add origin "$repo_url" 2>/dev/null || true
  git -C "$WORK" sparse-checkout init --cone 2>/dev/null || true
  git -C "$WORK" sparse-checkout set "$MT76_SUBDIR" 2>/dev/null || true

  # 最多 3 次；ref 可以是分支 / tag / sha，统一 checkout FETCH_HEAD 最稳
  local ok=0
  for i in 1 2 3; do
    echo "--- 第 $i 次 fetch ---"
    if git -C "$WORK" fetch -q --depth 1 origin "$MT76_REF" 2>/dev/null && \
       git -C "$WORK" checkout -q FETCH_HEAD 2>/dev/null; then
      ok=1; break
    fi
    sleep 5
  done

  if [ "$ok" != "1" ]; then
    # sparse-checkout 在某些 git 版本 / 老服务端上不支持，回退到整仓浅克隆
    warn "sparse 拉取失败，改为整仓浅克隆"
    rm -rf "$WORK"; mkdir -p "$WORK/repo"
    for i in 1 2 3; do
      if git clone -q --depth 1 -b "$MT76_REF" "$repo_url" "$WORK/repo" 2>/dev/null; then ok=1; break; fi
      sleep 5
    done
    [ "$ok" = "1" ] || return 1
    SRC_DIR="$WORK/repo/$MT76_SUBDIR"
  else
    SRC_DIR="$WORK/$MT76_SUBDIR"
  fi

  [ -f "$SRC_DIR/Makefile" ] || return 1
  return 0
}

case "$MT76_SOURCE" in
  vendored)
    prepare_vendored || { err "vendored 模式但 $CI_REPO/mt76/Makefile 不存在"; exit 1; }
    log "校验随仓库携带的 mt76: $SRC_DIR"
    verify_src "$SRC_DIR" && log "使用随仓库携带的 mt76" || {
      if [ "$MT76_STRICT" = "true" ]; then
        err "随仓库携带的 mt76 不合格（缺 NPU 开关或补丁）。"
        err "如需放行上游原版 mt76，请设 MT76_STRICT=false，或改用 MT76_SOURCE=none"
        exit 1
      fi
      warn "随仓库携带的 mt76 未通过严格校验（MT76_STRICT=false，继续）"
    }
    ;;
  remote)
    REMOTE_OK=0
    if prepare_remote; then
      log "校验远端 mt76: ${MT76_REPO}@${MT76_REF}"
      if verify_src "$SRC_DIR"; then
        REMOTE_OK=1
        log "远端 mt76 校验通过"
      else
        warn "远端 ${MT76_REPO}@${MT76_REF} 的 mt76 不是带 NPU 的版本（上游 ponwrt 本就不含 113 补丁）"
      fi
    else
      warn "远端 mt76 拉取失败（${MT76_REPO}@${MT76_REF}）"
    fi

    if [ "$REMOTE_OK" != "1" ]; then
      if [ "$MT76_FALLBACK" = "true" ] && prepare_vendored && verify_src "$SRC_DIR"; then
        warn "已回退到随仓库携带的 mt76（vendored）—— 这是带 NPU 的版本"
      elif [ "$MT76_FALLBACK" = "true" ] && prepare_vendored && [ "$MT76_STRICT" != "true" ]; then
        warn "已回退到随仓库携带的 mt76（未通过严格校验，MT76_STRICT=false 放行）"
      else
        err "远端 mt76 不可用且无合格回退（MT76_FALLBACK=${MT76_FALLBACK}）"
        err "提示：上游 qwe3017/ponwrt 的 mt76 不含 NPU 补丁，请用默认 vendored 或 MT76_STRICT=false"
        exit 1
      fi
    fi
    ;;
  *) err "未知的 MT76_SOURCE=$MT76_SOURCE（可选：vendored / remote / none）"; exit 1 ;;
esac

# ------------------------------------------------------------------
# 2) 覆盖：整目录替换，杜绝残留旧补丁
#
#    ⚠️ 不能只做 cp -r 合并 —— 若源码里本来有 113 之外的补丁，
#    合并后旧补丁还在，quilt 应用顺序错乱会直接打补丁失败。
# ------------------------------------------------------------------
log "覆盖 $DEST （先清空再拷入）"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -a "$SRC_DIR/." "$DEST/"

# ------------------------------------------------------------------
# 3) 校验：确认落到源码树里的确实是「带 NPU 的 mt76」
#    defconfig 不会报这种错，等到编 mt76 才发现就白跑一小时工具链
# ------------------------------------------------------------------
FAIL=0

if [ ! -f "$DEST/Makefile" ]; then
  err "覆盖后 $DEST/Makefile 不存在"; exit 1
fi

if [ "$MT76_STRICT" = "true" ]; then
  for m in "${NEED_MAKEFILE_MARKERS[@]}"; do
    if grep -q "$m" "$DEST/Makefile"; then
      echo "✅ Makefile 含 $m"
    else
      err "Makefile 缺少 $m —— 这不是带 NPU 的 mt76，mt7915 NPU 补丁不会生效"
      FAIL=1
    fi
  done

  for p in "${NEED_PATCHES[@]}"; do
    if [ -f "$DEST/patches/$p" ]; then
      echo "✅ 补丁就位: $p"
    else
      err "缺少补丁: $p"
      FAIL=1
    fi
  done
else
  echo "ℹ️  MT76_STRICT=false，跳过 NPU 特征校验"
fi

# 额外提示：非必需补丁只警告
OTHERS=$(ls -1 "$DEST/patches" 2>/dev/null | grep -cvE "^($(printf '%s|' "${NEED_PATCHES[@]}" | sed 's/|$//'))$" || true)
[ "${OTHERS:-0}" -gt 0 ] && echo "ℹ️  另有 $OTHERS 个非必需补丁，一并保留"

# 源码版本 / hash：写进日志便于回溯
PKG_VER="$(grep -m1 '^PKG_SOURCE_VERSION:=' "$DEST/Makefile" | sed 's/.*:=//')"
PKG_DATE="$(grep -m1 '^PKG_SOURCE_DATE:='   "$DEST/Makefile" | sed 's/.*:=//')"
echo "mt76 源码: ${PKG_DATE:-?} @ ${PKG_VER:-?}"

# ------------------------------------------------------------------
# 4) 清掉可能存在的旧构建产物与 stamp
#    dl 缓存 / 工具链缓存命中时，build_dir 里可能留着上一版 mt76，
#    不清的话 make 会认为 stamp 更新从而跳过重编，改完补丁却没生效
# ------------------------------------------------------------------
log "清理 mt76 旧构建产物与 stamp（best effort）"
rm -rf build_dir/target-*/linux-*/mt76* 2>/dev/null || true
find tmp -maxdepth 3 -type d -name 'mt76*' -exec rm -rf {} + 2>/dev/null || true
find tmp/stamp -type f -name '*mt76*' -delete 2>/dev/null || true

# ------------------------------------------------------------------
# 5) 输出元信息（供后续步骤 / Release 说明使用）
# ------------------------------------------------------------------
mkdir -p "$(dirname "$WORK")"
cat > .mt76-sync.env <<EOF
MT76_MODE=${MT76_SOURCE}
MT76_REPO=${MT76_REPO}
MT76_REF=${MT76_REF}
MT76_PKG_DATE=${PKG_DATE:-}
MT76_PKG_VERSION=${PKG_VER:-}
MT76_PATCHES=$(ls -1 "$DEST/patches" 2>/dev/null | tr '\n' ' ')
EOF

if [ "$FAIL" = "1" ]; then
  err "mt76 覆盖校验未通过，终止编译"
  exit 1
fi

echo "------------------------------------------"
echo "package/kernel/mt76 内容："
ls -1 "$DEST"
echo "  patches/:"
ls -1 "$DEST/patches" 2>/dev/null | sed 's/^/    /'
echo "------------------------------------------"
echo "🎉 mt76 同步完成 (source=${MT76_SOURCE})"

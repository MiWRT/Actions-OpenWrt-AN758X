#!/usr/bin/env bash
# ==================================================================
# fetch-mt76-local.sh —— 【本机手动下载专用】拉取 mt76 文件到本仓库 mt76/
#
# 用途：本机网络访问 GitHub 不通时，用 gh-proxy.com 把 mt76 的
#       Makefile + patches 抓下来，更新本仓库随仓库携带的 mt76/ 目录，
#       之后 CI 用 MT76_SOURCE=vendored 编译即可，不再依赖网络。
#
# ⚠️ 这个脚本**只在本机手动执行**。GitHub Actions runner 能直连 GitHub，
#    云端走 scripts/sync-mt76.sh 的 remote 模式，不需要（也不应该）用代理。
#
# ------------------------------------------------------------------
# 用法
# ------------------------------------------------------------------
#   # 默认：拉 qwe3017/ponwrt@master 的 package/kernel/mt76（走 gh-proxy）
#   ./scripts/fetch-mt76-local.sh
#
#   # 指定仓库 / 分支 / 子目录
#   REPO=qwe3017/ponwrt REF=master SUBDIR=package/kernel/mt76 \
#     ./scripts/fetch-mt76-local.sh
#
#   # 不走代理（比如你本机 GitHub 本来就通）
#   USE_PROXY=false ./scripts/fetch-mt76-local.sh
#
#   # 换别的前缀（gh-proxy.com 挂了时的备选）
#   GH_PROXY=https://ghfast.top/ ./scripts/fetch-mt76-local.sh
#
#   # 只下载、不覆盖本仓库 mt76/（先看看抓到的是啥）
#   DRY_RUN=true ./scripts/fetch-mt76-local.sh
#
# 输出：默认写到本仓库 mt76/ ；DRY_RUN=true 时写到 .mt76-fetch/
# ==================================================================
set -euo pipefail

REPO="${REPO:-qwe3017/ponwrt}"
REF="${REF:-master}"
SUBDIR="${SUBDIR:-package/kernel/mt76}"

# ---- 代理配置 ----
USE_PROXY="${USE_PROXY:-true}"
GH_PROXY="${GH_PROXY:-https://gh-proxy.com/}"   # 注意结尾的 /

# ---- 输出目录 ----
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN="${DRY_RUN:-false}"
if [ "$DRY_RUN" = "true" ]; then
  OUT_DIR="$HERE/.mt76-fetch"
else
  OUT_DIR="$HERE/mt76"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { echo "==> $*"; }
err() { echo "[ERROR] $*"; }

# ------------------------------------------------------------------
# 带代理的下载：先走代理，失败自动回退直连
# fetch <原始URL> <保存路径>
# ------------------------------------------------------------------
fetch() {
  local url="$1" dst="$2"
  local try_list=()

  if [ "$USE_PROXY" = "true" ]; then
    # gh-proxy 的用法是把原始 URL 直接拼在代理前缀后面
    try_list+=("${GH_PROXY}${url}")
  fi
  try_list+=("$url")

  for u in "${try_list[@]}"; do
    echo "    try: $u"
    if curl -fsSL --connect-timeout 15 --max-time 120 -o "$dst" "$u" 2>/dev/null; then
      # gh-proxy 出错时会返回一段 HTML/文本，简单判一下体积与内容
      if [ -s "$dst" ] && ! head -c 200 "$dst" | grep -qiE '<html|not found|404'; then
        echo "    ✅ ok ($(stat -c%s "$dst") bytes)"
        return 0
      fi
      echo "    内容异常，换下一个源"
    fi
  done
  return 1
}

echo "=========================================="
echo "本机拉取 mt76（代理: $([ "$USE_PROXY" = 'true' ] && echo "$GH_PROXY" || echo '关闭')）"
echo "  repo  : $REPO"
echo "  ref   : $REF"
echo "  subdir: $SUBDIR"
echo "  输出  : $OUT_DIR"
echo "=========================================="

mkdir -p "$OUT_DIR/patches"

# ------------------------------------------------------------------
# 1) 列出远端该目录下的文件
#    用 GitHub API 拿目录清单，比 raw 盲猜文件名可靠
# ------------------------------------------------------------------
API="https://api.github.com/repos/${REPO}/contents/${SUBDIR}?ref=${REF}"
log "获取目录清单"
if ! fetch "$API" "$TMP/listing.json"; then
  err "无法获取 ${SUBDIR} 的目录清单（网络/代理/仓库或路径不对？）"
  err "可手工在浏览器打开：${GH_PROXY}https://github.com/${REPO}/tree/${REF}/${SUBDIR}"
  exit 1
fi

# 解析 JSON（不依赖 jq：用 grep/sed 提取 name 与 type）
mapfile -t FILES < <(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$TMP/listing.json" | sed 's/.*: *"//; s/"$//')
if [ "${#FILES[@]}" -eq 0 ]; then
  err "目录清单为空：${SUBDIR}（检查 REPO/REF/SUBDIR）"
  head -c 400 "$TMP/listing.json"; echo
  exit 1
fi
echo "    发现 ${#FILES[@]} 项: ${FILES[*]}"

# ------------------------------------------------------------------
# 2) 下载 Makefile 与 patches/
# ------------------------------------------------------------------
BASE_RAW="https://raw.githubusercontent.com/${REPO}/${REF}/${SUBDIR}"

log "下载 Makefile"
fetch "${BASE_RAW}/Makefile" "$TMP/Makefile" || { err "Makefile 下载失败"; exit 1; }
cp "$TMP/Makefile" "$OUT_DIR/Makefile"
echo "✅ $OUT_DIR/Makefile ($(stat -c%s "$OUT_DIR/Makefile") bytes)"

# patches 目录单独列一次
API_P="https://api.github.com/repos/${REPO}/contents/${SUBDIR}/patches?ref=${REF}"
if fetch "$API_P" "$TMP/listing-p.json"; then
  mapfile -t PATCHES < <(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$TMP/listing-p.json" \
                          | sed 's/.*: *"//; s/"$//' | grep -E '\.patch$')
  echo "    patches/: ${#PATCHES[@]} 个"
  for p in "${PATCHES[@]}"; do
    echo "  -> $p"
    if fetch "${BASE_RAW}/patches/${p}" "$TMP/$p"; then
      cp "$TMP/$p" "$OUT_DIR/patches/$p"
    else
      err "补丁下载失败: $p"
      exit 1
    fi
  done
else
  echo "ℹ️  该仓库没有 patches/ 目录，跳过"
fi

# ------------------------------------------------------------------
# 3) 校验：确认是「带 NPU 的 mt76」
#    ponwrt 上游 master 目前只有 100/110 两个补丁，113（NPU vendor rewrite）
#    是需要额外带的；本机拉上游时这个文件可能不存在，要明确提示
# ------------------------------------------------------------------
echo "------------------------------------------"
echo "校验 mt76/ 内容"
MISSING=""
for m in CONFIG_MT76_NPU CONFIG_MT7915_NPU; do
  if grep -q "$m" "$OUT_DIR/Makefile"; then
    echo "✅ Makefile 含 $m"
  else
    echo "⚠️  Makefile 缺少 $m"
    MISSING="$MISSING $m"
  fi
done
for p in 100-wifi-mt76-mt7996-Use-tx_power-from-default-fw-if-EEP.patch \
         110-mt7915-add-mt7916-cal-free-merge.patch; do
  [ -f "$OUT_DIR/patches/$p" ] && echo "✅ $p" || { echo "⚠️  缺少 $p"; MISSING="$MISSING $p"; }
done

NPU_PATCH="$(ls -1 "$OUT_DIR/patches" 2>/dev/null | grep -c '113-mt7915-npu-vendor-rewrite.patch' || true)"
if [ "${NPU_PATCH:-0}" -ge 1 ]; then
  echo "✅ 113-mt7915-npu-vendor-rewrite.patch（MT7915/MT7916 NPU 卸载）"
else
  cat <<'NOTE'
⚠️  未发现 113-mt7915-npu-vendor-rewrite.patch

   上游 ponwrt 的 package/kernel/mt76 只有 100 / 110 两个补丁，
   NPU 卸载补丁（113）不在上游仓库里。若你要的是「AN7581 上 MT7916
   走 NPU 卸载」，请保留本仓库 mt76/patches 下已有的 113 号补丁，
   不要让它被上游目录覆盖 —— 本脚本默认只做「缺什么补什么」的拷贝，
   已存在的 113 不会被删。
NOTE
fi

echo "------------------------------------------"
if [ "$DRY_RUN" = "true" ]; then
  echo "DRY_RUN：文件在 $OUT_DIR（未写入 mt76/）"
else
  echo "已更新 $OUT_DIR"
  echo "下一步：git add mt76 && git commit -m 'mt76: sync' && git push"
  echo "        然后 CI 用 MT76_SOURCE=vendored 编译（默认即为此值）"
fi

# Makefile 缺 NPU 标记时给非零提示但不阻断（上游本来就没有）
if [ -n "$MISSING" ]; then
  echo ""
  echo "注意：缺少以下项 —— $MISSING"
  echo "      上游 ponwrt 的 mt76 本就不含 NPU 开关；如需 NPU 卸载，"
  echo "      请手动把 113 号补丁与含 CONFIG_MT7915_NPU 的 Makefile 放回 mt76/。"
fi

#!/usr/bin/env bash
# 取面板分发包（默认从 h5000m-mt5700-panel 的 release 下载）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"; mkdir -p "$OUT"
PANEL_REPO="${PANEL_REPO:-ctr54188/h5000m-mt5700-panel}"
PANEL_TAG="${PANEL_TAG:-}"

if [ -n "${PANEL_TARBALL:-}" ]; then
	echo "== 使用本地面板包：$PANEL_TARBALL"
	cp "$PANEL_TARBALL" "$OUT/"
	exit 0
fi

API="https://api.github.com/repos/$PANEL_REPO/releases"
URL="$API/latest"
[ -n "$PANEL_TAG" ] && URL="$API/tags/$PANEL_TAG"
echo "== 查询 $URL"
ASSET="$(curl -fsSL "$URL" | grep -o '"browser_download_url": *"[^"]*\.tar\.gz"' | head -1 | sed 's/.*"\(http[^"]*\)"/\1/')"
[ -n "$ASSET" ] || { echo "!! $PANEL_REPO 的 release 里没有 .tar.gz 资产" >&2; exit 1; }
echo "== 下载 $ASSET"
curl -fL "$ASSET" -o "$OUT/$(basename "$ASSET")"
curl -fsL "$ASSET.sha256" -o "$OUT/$(basename "$ASSET").sha256" 2>/dev/null || true
ls -l "$OUT"/h5000m-mt5700-panel-*.tar.gz

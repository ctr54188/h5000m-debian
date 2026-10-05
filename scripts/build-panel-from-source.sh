#!/usr/bin/env bash
# 回退路径：A 仓库没有可用 release 时，直接 clone 面板仓库源码在本地构建。
# 只做 git clone / cargo build，不会触发 A 仓库的任何 GitHub Actions。
# 输出（stdout）：生成的 tar.gz 路径。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${PANEL_SRC_DIR:-$ROOT/build/panel-src}"
REPO="${PANEL_REPO:-ctr54188/h5000m-mt5700-panel}"
TAG="${PANEL_TAG:-}"

log() { echo "== $*" >&2; }

rm -rf "$WORK"
if [ -n "$TAG" ]; then
	log "clone $REPO @ $TAG"
	git clone --depth 1 --branch "$TAG" "https://github.com/$REPO.git" "$WORK"
else
	log "clone $REPO (默认分支)"
	git clone --depth 1 "https://github.com/$REPO.git" "$WORK"
fi

cd "$WORK"
log "编译面板（本机架构）"
TARGET= make build >&2
TARGET= make dist  >&2

TAR="$(ls -t "$WORK"/build/h5000m-mt5700-panel-*.tar.gz | head -1)"
[ -f "$TAR" ] || { echo "!! 面板构建未产出 tar.gz" >&2; exit 1; }
cp "$TAR" "$ROOT/build/" 2>/dev/null || true
log "面板包：$TAR"
printf '%s\n' "$TAR"

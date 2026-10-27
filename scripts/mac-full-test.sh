#!/usr/bin/env bash
# TileProto macOS 全面测试：自测 → 构建 → 启动 → 辅助功能检查 → 交互清单报告
# 用法（在 Mac 上）:
#   git fetch origin cursor/live-demo-parity-0145
#   git checkout cursor/live-demo-parity-0145
#   ./scripts/mac-full-test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${TILEPROTO_TEST_OUT:-$HOME/tileproto-test-$STAMP}"
mkdir -p "$OUT_DIR/shots"
REPORT="$OUT_DIR/report.md"
SELFTEST_BIN="$OUT_DIR/tileproto-selftest"
APP="$ROOT/TileProto.app"
PASS=0
FAIL=0
SKIP=0

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "## $*"; log ""; }
ok() { PASS=$((PASS+1)); log "- PASS: $*"; }
bad() { FAIL=$((FAIL+1)); log "- FAIL: $*"; }
skip() { SKIP=$((SKIP+1)); log "- SKIP: $*"; }

: > "$REPORT"
log "# TileProto mac full test"
log ""
log "- started: $(date '+%Y-%m-%d %H:%M:%S %z')"
log "- repo: $ROOT"
log "- commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown) ($(git branch --show-current 2>/dev/null || echo detached))"
log "- out: $OUT_DIR"

section "Host"
if [[ "$(uname -s)" != "Darwin" ]]; then
  bad "not Darwin (uname=$(uname -s))"
  log ""
  log "TOTAL pass=$PASS fail=$FAIL skip=$SKIP"
  exit 2
fi
ok "Darwin $(uname -m)"
log "- sw_vers: $(sw_vers -productVersion 2>/dev/null || true)"
if command -v swiftc >/dev/null 2>&1; then
  ok "swiftc available"
  log '```'
  swiftc --version 2>&1 | tee -a "$REPORT" || true
  log '```'
else
  bad "swiftc missing — install Xcode CLT"
  log ""
  log "TOTAL pass=$PASS fail=$FAIL skip=$SKIP"
  exit 2
fi

section "TILEPROTO_SELFTEST"
set +e
swiftc -D TILEPROTO_SELFTEST main.swift \
  -framework AppKit -framework ApplicationServices \
  -o "$SELFTEST_BIN" >"$OUT_DIR/selftest-compile.log" 2>&1
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  bad "selftest compile failed (exit $RC)"
  log '```'
  cat "$OUT_DIR/selftest-compile.log" | tee -a "$REPORT"
  log '```'
else
  ok "selftest compiled"
  set +e
  "$SELFTEST_BIN" >"$OUT_DIR/selftest-run.log" 2>&1
  RC=$?
  set -e
  log '```'
  cat "$OUT_DIR/selftest-run.log" | tee -a "$REPORT"
  log '```'
  if [[ $RC -eq 0 ]] && grep -q 'SELFTEST OK' "$OUT_DIR/selftest-run.log"; then
    ok "selftest SELFTEST OK"
  else
    bad "selftest run failed (exit $RC)"
  fi
fi

section "build.sh"
set +e
./build.sh >"$OUT_DIR/build.log" 2>&1
RC=$?
set -e
log '```'
tail -n 80 "$OUT_DIR/build.log" | tee -a "$REPORT"
log '```'
if [[ $RC -eq 0 && -d "$APP" ]]; then
  ok "build produced TileProto.app"
  log "- app: $APP"
  log "- binary: $(ls -la "$APP/Contents/MacOS/" 2>/dev/null | tail -n +2 | tee -a "$REPORT" || true)"
else
  bad "build failed (exit $RC) or app missing"
fi

section "Accessibility trust probe"
# 不弹系统提示：只读当前进程是否已信任（本脚本本身通常未列入）。
# 真正要测的是 TileProto.app 二进制是否在辅助功能名单里。
set +e
python3 - <<'PY' >"$OUT_DIR/ax-probe.txt" 2>&1
import subprocess, os, sys
app = os.environ.get("APP_PATH", "")
print("app", app)
# 用 tccutil / sqlite 太侵入；改为：启动后读日志里的 trusted 行，并提示用户看菜单栏图标。
print("probe: open app and watch menu bar icon ▦ vs ▦!")
print("manual: System Settings → Privacy & Security → Accessibility → enable TileProto")
PY
RC=$?
set -e
APP_PATH="$APP" python3 - <<'PY' >"$OUT_DIR/ax-probe.txt" 2>&1 || true
import os
print("app", os.environ.get("APP_PATH"))
print("Grant Accessibility to TileProto.app after each rebuild (unsigned binary changes identity).")
PY
log '```'
cat "$OUT_DIR/ax-probe.txt" | tee -a "$REPORT"
log '```'
skip "AX grant is interactive — verify menu bar icon becomes ▦ after enabling TileProto"

section "Launch app"
if [[ -d "$APP" ]]; then
  # 关掉旧实例，避免测到旧二进制
  osascript -e 'tell application "System Events" to set procs to name of every process whose name is "TileProto"' >/dev/null 2>&1 || true
  pkill -x TileProto 2>/dev/null || true
  sleep 0.4
  open "$APP"
  sleep 1.2
  if pgrep -x TileProto >/dev/null 2>&1; then
    ok "TileProto process running (pid $(pgrep -x TileProto | tr '\n' ' '))"
  else
    bad "TileProto did not stay running — check Gatekeeper / crash logs"
  fi
  # 截一张全屏作证据（不含窗口内容隐私承诺：只作布局证据）
  if command -v screencapture >/dev/null 2>&1; then
    screencapture -x "$OUT_DIR/shots/desktop-after-launch.png" 2>/dev/null || true
    if [[ -f "$OUT_DIR/shots/desktop-after-launch.png" ]]; then
      ok "screenshot $OUT_DIR/shots/desktop-after-launch.png"
    else
      skip "screencapture failed (Screen Recording permission?)"
    fi
  fi
else
  skip "no app to launch"
fi

section "Interactive checklist (fill by hand on this Mac)"
log "在菜单栏点 ▦ 打开面板，按项打勾，结果写回本报告或口头确认："
log ""
log "1. [ ] 自动平铺开着时，新开 TextEdit/Notes 窗口会进格子"
log "2. [ ] Grid / Columns / Rows / Side 切换立刻重排"
log "3. [ ] 数量 1–4；装不下的档位变灰"
log "4. [ ] Gap 可到 24；单窗也有边距"
log "5. [ ] Grid + 60% + 四格：左列更宽，左右各自上下对半"
log "6. [ ] 满格后再开窗：Stack when full → 进活动格；Float when full → 居中浮动"
log "7. [ ] ⌘ 拖到另一格 → 交换；目标格略内收"
log "8. [ ] ⌥⌘ 拖到另一格 → 进叠，高亮 Add to stack（不是 Control）"
log "9. [ ] 拖动中途松开 Option 再松手 → 变成交换"
log "10. [ ] 普通拖 → 弹回，提示 A plain drag never rearranges / Hold ⌘ to swap"
log "11. [ ] 悬停约 0.15s 出条：Primary / Focus / Float"
log "12. [ ] No peek + Dim 10–90；Borders；Clean Space；恢复浮动"
log "13. [ ] 拖分隔缝跟手，Reset sizes 清比例"
log ""

section "Summary"
log "- pass=$PASS fail=$FAIL skip=$SKIP"
log "- report: $REPORT"
log "- finished: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo
echo "Report: $REPORT"
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0

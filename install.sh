#!/usr/bin/env bash
# install.sh — 安裝／卸載 LaunchAgent。
#
# 用法：
#   ./install.sh            安裝（檢查依賴 → 建目錄 → 產生 plist → bootstrap → 測試通知）
#   ./install.sh uninstall  卸載（bootout LaunchAgent → 刪除已安裝的 plist）
#
# 注意：本檔由 Saber 手動執行安裝動作；開發階段不應被自動呼叫。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=./notify.sh
source "$SCRIPT_DIR/notify.sh"

PLIST_LABEL="com.saber.goultra"
PLIST_SRC="$SCRIPT_DIR/com.saber.goultra.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

_check_deps() {
    echo "檢查依賴..."
    local missing=()
    for cmd in curl rsync caffeinate; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if [[ ! -x "$CLAUDE_BIN" ]]; then
        echo "警告：找不到 claude CLI（${CLAUDE_BIN}）。Phase 2 headless 剪輯將無法執行，Phase 1（觸發/匯入/通知）不受影響。"
    fi
    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "警告：以下依賴缺失，Phase 1 可能無法正常運作：${missing[*]}"
    else
        echo "依賴檢查通過：curl / rsync / caffeinate 皆存在。"
    fi
}

_install() {
    _check_deps

    echo "建立必要目錄..."
    mkdir -p "$LOG_DIR"
    mkdir -p "$RAW_DEST"

    echo "產生 plist（替換路徑占位字串）..."
    sed -e "s#__REPO_DIR__#${SCRIPT_DIR}#g" -e "s#__LOG_DIR__#${LOG_DIR}#g" \
        "$PLIST_SRC" > "$PLIST_DEST"
    echo "已寫入：$PLIST_DEST"

    echo "卸載舊版本（若有，容錯）..."
    launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true

    echo "載入 LaunchAgent..."
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
    echo "已載入 LaunchAgent：$PLIST_LABEL"

    echo "發送測試通知..."
    NTFY_DRYRUN=0 notify "default" "goultra-autopilot 安裝完成" "LaunchAgent 已載入，插入 Go Ultra 即會觸發匯入流程。"

    echo "安裝完成。"
}

_uninstall() {
    echo "卸載 LaunchAgent..."
    launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true
    if [[ -f "$PLIST_DEST" ]]; then
        rm -f "$PLIST_DEST"
        echo "已移除：$PLIST_DEST"
    else
        echo "找不到已安裝的 plist（可能本來就沒裝），略過。"
    fi
    echo "卸載完成。"
}

case "${1:-install}" in
    install)
        _install
        ;;
    uninstall)
        _uninstall
        ;;
    *)
        echo "用法：$0 [install|uninstall]" >&2
        exit 1
        ;;
esac

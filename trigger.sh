#!/usr/bin/env bash
# trigger.sh — launchd StartOnMount 進入點。
#
# 任何磁碟掛載都會執行本檔；由本檔自行判斷該磁碟是否為 Go Ultra，
# 不是的話靜默退出（不通知——每次隨身碟掛載都會跑到這裡，不能吵）。
#
# 流程：辨識 Go Ultra → lockfile 防重入 → caffeinate 防睡眠 →
#       呼叫 ingest.sh → 依退出碼決定下一步（Phase 2 目前只是 stub）。
#
# 外層兜底：任何未預期錯誤都會被 ERR trap 捕捉，推送高優先級失敗通知。

set -uo pipefail
# 注意：這裡不用 `set -e`，因為「辨識 Go Ultra」與「lockfile 檢查」的分支
# 需要在條件不成立時自行 exit，若用 -e 一旦某個測試指令回傳非零
# （例如 pgrep 找不到行程）會被誤判為腳本錯誤而提前中止。
# 我們改為在每個關鍵指令後自行檢查回傳值。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=./notify.sh
source "$SCRIPT_DIR/notify.sh"

mkdir -p "$LOG_DIR"
RUN_TS="$(date '+%Y%m%d-%H%M%S')"
NOTIFY_LOG_FILE="$LOG_DIR/run-${RUN_TS}.log"
export NOTIFY_LOG_FILE

# 把本次執行的所有 stdout/stderr 都導入 log（同時仍保留給 launchd 自己的
# StandardOut/ErrPath，兩邊都有一份不衝突）。
exec >>"$NOTIFY_LOG_FILE" 2>&1

echo "===== trigger.sh 開始執行 $(date '+%Y-%m-%d %H:%M:%S') ====="

# ---- 外層兜底：任何未預期錯誤 → 高優先級通知＋log 摘要 ----
_on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    _notify_log "trigger.sh 發生未預期錯誤（line ${line_no}, exit ${exit_code}）"
    local tail_summary
    tail_summary="$(tail -n 10 "$NOTIFY_LOG_FILE" 2>/dev/null | tr '\n' ' ')"
    notify "urgent" "goultra-autopilot 失敗" "trigger.sh 在 line ${line_no} 發生錯誤（exit ${exit_code}）。log 末尾：${tail_summary}"
    _release_lock
    exit "$exit_code"
}

trap '_on_error $LINENO' ERR

# ---- lockfile 管理 ----
_release_lock() {
    if [[ -n "${LOCK_ACQUIRED:-}" ]]; then
        rm -f "$LOCKFILE"
    fi
}

LOCK_ACQUIRED=""

_acquire_lock() {
    if [[ -f "$LOCKFILE" ]]; then
        local old_pid
        old_pid="$(cat "$LOCKFILE" 2>/dev/null || echo "")"
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            _notify_log "lockfile 存在且 PID $old_pid 仍在執行，本次退出"
            echo "已有一份 trigger.sh 在執行（PID ${old_pid}），退出。"
            exit 0
        else
            _notify_log "發現殘留 lockfile（PID $old_pid 已死），清除後繼續"
            rm -f "$LOCKFILE"
        fi
    fi
    echo "$$" > "$LOCKFILE"
    LOCK_ACQUIRED=1
}

trap '_release_lock' EXIT

# ---- 辨識 Go Ultra 磁碟 ----
_find_goultra_volume() {
    if [[ -n "${GOULTRA_TEST_VOLUME:-}" ]]; then
        if [[ -d "$GOULTRA_TEST_VOLUME" ]]; then
            echo "$GOULTRA_TEST_VOLUME"
            return 0
        else
            _notify_log "GOULTRA_TEST_VOLUME 設定了但目錄不存在：$GOULTRA_TEST_VOLUME"
            return 1
        fi
    fi

    local vol
    for vol in /Volumes/*; do
        [[ -d "$vol" ]] || continue
        local vol_name
        vol_name="$(basename "$vol")"

        # 條件一：磁碟名稱符合 GOULTRA_NAME_PATTERN。
        # shellcheck disable=SC2053
        if [[ "$vol_name" == $GOULTRA_NAME_PATTERN ]]; then
            echo "$vol"
            return 0
        fi

        # 條件二：Insta360 內容指紋（2026-07-14 真卡校準：Go Ultra 掛載名是「Untitled」，
        # 名稱不可靠；改認 DCIM/Camera01/fileinfo_list.list 這個 Insta360 特有檔案）。
        if [[ -d "$vol/DCIM" ]] && [[ -f "$vol/DCIM/fileinfo_list.list" || -f "$vol/DCIM/Camera01/fileinfo_list.list" ]]; then
            echo "$vol"
            return 0
        fi
    done
    return 1
}

# 注意：不能寫成 VAR="$(func)" 直接賦值——set -e＋ERR trap 下，函式回傳非零會在
# 賦值行直接觸發 trap（2026-07-14 真卡首插實測踩坑，line 115 誤報 unexpected error），
# 用 || true 吃掉狀態碼，靠空值判斷。
GOULTRA_VOLUME="$(_find_goultra_volume || true)"

if [[ -z "$GOULTRA_VOLUME" ]]; then
    echo "未偵測到 Go Ultra 磁碟，靜默退出。"
    exit 0
fi

echo "偵測到 Go Ultra 磁碟：$GOULTRA_VOLUME"

_acquire_lock

# ---- caffeinate 防睡眠 + 呼叫 ingest.sh ----
notify "default" "Go Ultra 已連接" "偵測到 Go Ultra（${GOULTRA_VOLUME}），開始匯入素材。"

# 注意：bash 3.2（macOS 系統內建版本）有個特性——即使 `set +e` 生效中，
# ERR trap 仍會在 `wait` 回傳非零時被觸發（trap 不看當下的 -e 狀態）。
# ingest.sh 用非零退出碼（10）表達「正常情況：無新素材」，不是真正的錯誤，
# 所以這裡連 trap 本身都要暫時清空，讀完狀態碼後才恢復，避免誤報成失敗。
trap - ERR
set +e
caffeinate -i -w $$ "$SCRIPT_DIR/ingest.sh" "$GOULTRA_VOLUME" &
INGEST_PID=$!
wait "$INGEST_PID"
INGEST_STATUS=$?
set -e
trap '_on_error $LINENO' ERR

case "$INGEST_STATUS" in
    0)
        echo "ingest.sh 回報：有新素材，全部匯入成功。"
        # Phase 2 stub：headless 剪輯尚未啟用。
        notify "default" "Go Ultra 自動剪輯" "素材已匯入，headless 剪輯 Phase 2 尚未啟用。"
        _notify_log "run_edit_session stub: Phase 2 尚未實作，本次僅完成匯入。"
        ;;
    10)
        echo "ingest.sh 回報：無新素材（僅充電或已匯入過）。"
        notify "default" "Go Ultra 已連接" "偵測到 Go Ultra，無新素材，僅充電/已匯入過。"
        ;;
    *)
        echo "ingest.sh 回報失敗，exit code $INGEST_STATUS"
        tail_summary="$(tail -n 10 "$NOTIFY_LOG_FILE" 2>/dev/null | tr '\n' ' ')"
        notify "urgent" "Go Ultra 匯入失敗" "ingest.sh 失敗（exit ${INGEST_STATUS}）。log 末尾：${tail_summary}"
        ;;
esac

echo "===== trigger.sh 執行結束 $(date '+%Y-%m-%d %H:%M:%S') ====="
exit 0

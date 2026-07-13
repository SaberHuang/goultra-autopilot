#!/usr/bin/env bash
# notify.sh — 通知函式庫（shell 層用，封裝 ntfy.sh 的 curl 呼叫）。
#
# 使用方式：
#   source config.sh
#   source notify.sh
#   notify <priority> <title> <message> [image_path]
#
# priority: ntfy 的優先級字串，例如 min / low / default / high / urgent。
# image_path（選填）：若提供，會以 --data-binary @file 附上圖片，並帶 Filename header。
#
# 設計原則：notify 永遠不可讓呼叫端流程中斷——curl 失敗只記 log，
# 函式本身永遠 return 0。NTFY_DRYRUN=1 時完全不對外連線，只寫 log，
# 方便測試環境使用。

# 需要 config.sh 已經被 source 過（提供 NTFY_SERVER / NTFY_TOPIC / NTFY_DRYRUN / LOG_DIR）。
# 這裡不重複 source config.sh，避免測試時的變數覆寫被沖掉。

# 內部用：目前這次執行的 log 檔路徑。呼叫端（trigger.sh）應在啟動時設定
# NOTIFY_LOG_FILE，若未設定則 fallback 到 stderr。
: "${NOTIFY_LOG_FILE:=}"

_notify_log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [[ -n "$NOTIFY_LOG_FILE" ]]; then
        echo "$line" >> "$NOTIFY_LOG_FILE"
    else
        echo "$line" >&2
    fi
}

notify() {
    local priority="${1:-default}"
    local title="${2:-goultra-autopilot}"
    local message="${3:-}"
    local image_path="${4:-}"

    if [[ "${NTFY_DRYRUN:-0}" == "1" ]]; then
        _notify_log "DRYRUN notify: priority=$priority title=\"$title\" message=\"$message\" image=\"$image_path\""
        return 0
    fi

    local url="${NTFY_SERVER:-https://ntfy.sh}/${NTFY_TOPIC:?NTFY_TOPIC 未設定}"
    local http_code

    if [[ -n "$image_path" && -f "$image_path" ]]; then
        http_code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
            -H "Title: $title" \
            -H "Priority: $priority" \
            -H "Filename: $(basename "$image_path")" \
            --data-binary "@${image_path}" \
            "$url" 2>>"${NOTIFY_LOG_FILE:-/dev/null}") || http_code="curl_failed"
    else
        http_code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' \
            -H "Title: $title" \
            -H "Priority: $priority" \
            -d "$message" \
            "$url" 2>>"${NOTIFY_LOG_FILE:-/dev/null}") || http_code="curl_failed"
    fi

    if [[ "$http_code" == "200" ]]; then
        _notify_log "notify OK: priority=$priority title=\"$title\" message=\"$message\""
    else
        _notify_log "notify FAILED (http_code=$http_code): priority=$priority title=\"$title\" message=\"$message\""
    fi

    return 0
}

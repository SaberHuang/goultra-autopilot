#!/usr/bin/env bash
# ingest.sh <volume_path> — 比對 manifest、rsync 新素材、寫 manifest、發匯入通知。
#
# 鐵律：絕對唯讀對待記憶卡。不得刪除、搬移、寫入卡上任何東西
# （不使用 --remove-source-files 之類的選項）。
#
# 退出碼：
#   0  = 有新檔且全部匯入成功
#   10 = 無新檔（卡上素材全部已匯入過）
#   1  = 有檔案匯入失敗（部分或全部）
#
# 使用方式：
#   ingest.sh /Volumes/Insta360

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "$SCRIPT_DIR/config.sh"
# shellcheck source=./notify.sh
source "$SCRIPT_DIR/notify.sh"

VOLUME_PATH="${1:?ingest.sh 需要一個參數：volume_path}"

if [[ ! -d "$VOLUME_PATH" ]]; then
    _notify_log "ingest.sh: volume_path 不存在或不是目錄：$VOLUME_PATH"
    echo "ERROR: volume_path 不存在或不是目錄：$VOLUME_PATH" >&2
    exit 1
fi

DCIM_DIR="$VOLUME_PATH/DCIM"
if [[ ! -d "$DCIM_DIR" ]]; then
    _notify_log "ingest.sh: 找不到 DCIM 目錄：$DCIM_DIR"
    echo "ERROR: 找不到 DCIM 目錄：$DCIM_DIR" >&2
    exit 1
fi

TODAY="$(date '+%Y%m%d')"
DEST_DIR="$RAW_DEST/$TODAY"

mkdir -p "$RAW_DEST"
mkdir -p "$DEST_DIR"

# manifest 檔若不存在就建立一個空的。
touch "$MANIFEST"

# 收集卡上 DCIM/ 下所有 mp4（大小寫都收），排除 .lrv 低解析代理檔。
# 用 find -print0 / 讀取 NUL 分隔，安全處理含空白的檔名。
# 註：不用 `mapfile`（bash 4+ builtin）——macOS 系統內建 /bin/bash 是 3.2，
# launchd 執行環境也不保證有較新版 bash 可用，這裡改用相容 bash 3.2 的 while read 迴圈。
CANDIDATE_FILES=()
while IFS= read -r -d '' _cand_file; do
    CANDIDATE_FILES+=("$_cand_file")
done < <(find "$DCIM_DIR" -type f \( -iname '*.mp4' \) -print0)

TOTAL_CANDIDATES=${#CANDIDATE_FILES[@]}

if [[ "$TOTAL_CANDIDATES" -eq 0 ]]; then
    _notify_log "ingest.sh: DCIM 下沒有任何 mp4 檔案"
    notify "default" "Go Ultra 已連接" "偵測到 Go Ultra，DCIM 內無 mp4 素材。"
    exit 10
fi

# --- 建立「候選檔案 → (檔名, 大小, mtime_epoch, 排序用 mtime)」對照 ---
# 用平行陣列而非 associative array，避免對含特殊字元檔名的 key 產生問題。

NEW_FILES=()
NEW_FILES_MTIME=()
FAILED_FILES=()
IMPORTED_COUNT=0
IMPORTED_BYTES=0

for src_file in "${CANDIDATE_FILES[@]}"; do
    base_name="$(basename "$src_file")"

    # 排除 .lrv（低解析代理檔）；理論上 -iname '*.mp4' 已排除非 mp4 副檔名，
    # 這裡再做一次防呆（避免 Insta360 有 "xxx.lrv.mp4" 之類的異常命名）。
    if [[ "$base_name" == *.lrv || "$base_name" == *.LRV ]]; then
        continue
    fi

    file_size="$(stat -f '%z' "$src_file")"
    file_mtime="$(stat -f '%m' "$src_file")"

    manifest_key="${base_name}|${file_size}|${file_mtime}"

    if grep -qxF "$manifest_key" "$MANIFEST" 2>/dev/null; then
        # 檔名、大小、mtime 三者全同 = 已匯入過，跳過。
        continue
    fi

    dest_file="$DEST_DIR/$base_name"

    # rsync 單檔複製；--checksum 確保內容比對而非僅時間戳；不加任何會動到來源的選項。
    if rsync --checksum --times --perms "$src_file" "$dest_file" 2>>"${NOTIFY_LOG_FILE:-/dev/null}"; then
        dest_size="$(stat -f '%z' "$dest_file" 2>/dev/null || echo -1)"
        if [[ "$dest_size" == "$file_size" ]]; then
            echo "$manifest_key" >> "$MANIFEST"
            NEW_FILES+=("$dest_file")
            NEW_FILES_MTIME+=("$file_mtime")
            IMPORTED_COUNT=$((IMPORTED_COUNT + 1))
            IMPORTED_BYTES=$((IMPORTED_BYTES + file_size))
        else
            FAILED_FILES+=("$base_name (size mismatch: src=$file_size dest=$dest_size)")
        fi
    else
        FAILED_FILES+=("$base_name (rsync failed)")
    fi
done

if [[ "$IMPORTED_COUNT" -eq 0 && "${#FAILED_FILES[@]}" -eq 0 ]]; then
    _notify_log "ingest.sh: 卡上所有素材皆已匯入過，本次無新檔"
    notify "default" "Go Ultra 已連接" "偵測到 Go Ultra，無新素材（已匯入過或僅充電）。"
    exit 10
fi

# 依拍攝 mtime 排序，寫出 .batch_files（Phase 2 找留言檔要用：完整路徑，按 mtime 排序）。
if [[ "$IMPORTED_COUNT" -gt 0 ]]; then
    BATCH_FILE="$DEST_DIR/.batch_files"
    : > "$BATCH_FILE"
    # 產生 "mtime\tpath" 再排序，取出 path
    {
        for i in "${!NEW_FILES[@]}"; do
            printf '%s\t%s\n' "${NEW_FILES_MTIME[$i]}" "${NEW_FILES[$i]}"
        done
    } | sort -n -k1,1 | cut -f2- > "$BATCH_FILE"
fi

IMPORTED_GB="$(awk -v b="$IMPORTED_BYTES" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }')"

if [[ "${#FAILED_FILES[@]}" -gt 0 ]]; then
    fail_list="$(printf '%s; ' "${FAILED_FILES[@]}")"
    _notify_log "ingest.sh: 匯入完成但有失敗檔：$fail_list"
    notify "high" "Go Ultra 匯入部分失敗" "成功匯入 ${IMPORTED_COUNT} 支（共 ${IMPORTED_GB} GB）→ ${DEST_DIR}；失敗：${fail_list}"
    exit 1
fi

_notify_log "ingest.sh: 匯入成功 $IMPORTED_COUNT 檔，共 $IMPORTED_GB GB → $DEST_DIR"
notify "default" "Go Ultra 匯入完成" "匯入 ${IMPORTED_COUNT} 支素材（共 ${IMPORTED_GB} GB）→ ${DEST_DIR}"
exit 0

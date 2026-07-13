#!/usr/bin/env bash
# test/fake-mount.sh — 端到端測試：模擬插入 Go Ultra，驗證 trigger.sh 全流程。
#
# 不得碰到真實的 /Users/saber/03_FCPX/Insta360_RAW；所有路徑都用
# mktemp -d 建立在可寫的臨時目錄下，並透過環境變數覆寫 config.sh 預設值。
#
# 驗證項目：
#   a. 第一輪匯入恰好 3 檔（.lrv 未匯入），目的資料夾/manifest/.batch_files 正確
#   b. 第二輪匯入 0 檔（退出路徑=無新素材）
#   c. 假卡全部檔案 md5 與檔案數，前後不變（唯讀鐵律）
#   d. log 裡有 dry-run 的 notify 記錄
#
# 全過印 "ALL PASS"；任一失敗印 "FAIL: <原因>" 並以非零碼結束。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FAIL_REASON=""

_fail() {
    FAIL_REASON="$1"
    echo "FAIL: $FAIL_REASON"
    exit 1
}

# ---- 建立臨時測試環境 ----

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/goultra-autopilot-test.XXXXXX")"
FAKE_VOLUME="$TEST_ROOT/fake_volume"
FAKE_DCIM="$FAKE_VOLUME/DCIM/Camera01"
TEST_RAW_DEST="$TEST_ROOT/raw_dest"
TEST_LOG_DIR="$TEST_ROOT/logs"
TEST_LOCKFILE="$TEST_ROOT/goultra-autopilot-test.lock"

mkdir -p "$FAKE_DCIM"
mkdir -p "$TEST_RAW_DEST"
mkdir -p "$TEST_LOG_DIR"

echo "測試環境：$TEST_ROOT"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

# ---- 產生假素材 ----
# 3 個假 mp4（1-5MB 隨機內容），mtime 錯開；1 個 .lrv（應被排除）。

_make_fake_file() {
    local path="$1"
    local size_mb="$2"
    local mtime="$3"  # touch -t 格式：[[CC]YY]MMDDhhmm[.SS]
    dd if=/dev/urandom of="$path" bs=1m count="$size_mb" >/dev/null 2>&1
    touch -t "$mtime" "$path"
}

_make_fake_file "$FAKE_DCIM/VID_20260701_0001.mp4" 1 "202607010800"
_make_fake_file "$FAKE_DCIM/VID_20260701_0002.mp4" 3 "202607010805"
_make_fake_file "$FAKE_DCIM/VID_20260701_0003.mp4" 2 "202607010810"
_make_fake_file "$FAKE_DCIM/VID_20260701_0003.lrv" 1 "202607010810"

echo "假素材已建立：3 個 mp4 + 1 個 .lrv"

# 記錄假卡所有檔案的 md5 與檔案數（唯讀鐵律驗證用）。
_snapshot_volume() {
    find "$FAKE_VOLUME" -type f -print0 | sort -z | xargs -0 md5 -r 2>/dev/null
}

SNAPSHOT_BEFORE="$(_snapshot_volume)"
COUNT_BEFORE="$(find "$FAKE_VOLUME" -type f | wc -l | tr -d ' ')"

# ---- 執行第一輪 trigger.sh ----

RUN1_LOG_PATTERN="$TEST_LOG_DIR/run-*.log"

env \
    GOULTRA_TEST_VOLUME="$FAKE_VOLUME" \
    NTFY_DRYRUN=1 \
    RAW_DEST="$TEST_RAW_DEST" \
    MANIFEST="$TEST_RAW_DEST/.imported_manifest" \
    LOG_DIR="$TEST_LOG_DIR" \
    LOCKFILE="$TEST_LOCKFILE" \
    bash "$REPO_DIR/trigger.sh"
RUN1_STATUS=$?

if [[ "$RUN1_STATUS" -ne 0 ]]; then
    _fail "第一輪 trigger.sh 非零退出碼：$RUN1_STATUS"
fi

# ---- 驗證 (a)：第一輪匯入恰好 3 檔 ----

TODAY="$(date '+%Y%m%d')"
DEST_DIR="$TEST_RAW_DEST/$TODAY"

if [[ ! -d "$DEST_DIR" ]]; then
    _fail "目的資料夾不存在：$DEST_DIR"
fi

IMPORTED_COUNT="$(find "$DEST_DIR" -type f -iname '*.mp4' | wc -l | tr -d ' ')"
if [[ "$IMPORTED_COUNT" -ne 3 ]]; then
    _fail "第一輪匯入檔數不是 3，實際：${IMPORTED_COUNT}（目錄：${DEST_DIR}）"
fi

if find "$DEST_DIR" -iname '*.lrv' | grep -q .; then
    _fail ".lrv 檔案被匯入了，違反排除規則"
fi

MANIFEST_FILE="$TEST_RAW_DEST/.imported_manifest"
if [[ ! -f "$MANIFEST_FILE" ]]; then
    _fail "manifest 檔不存在：$MANIFEST_FILE"
fi

MANIFEST_LINES="$(wc -l < "$MANIFEST_FILE" | tr -d ' ')"
if [[ "$MANIFEST_LINES" -ne 3 ]]; then
    _fail "manifest 行數不是 3，實際：$MANIFEST_LINES"
fi

if grep -q '\.lrv' "$MANIFEST_FILE"; then
    _fail "manifest 內含 .lrv 記錄，違反排除規則"
fi

BATCH_FILE="$DEST_DIR/.batch_files"
if [[ ! -f "$BATCH_FILE" ]]; then
    _fail ".batch_files 不存在：$BATCH_FILE"
fi

BATCH_LINES="$(wc -l < "$BATCH_FILE" | tr -d ' ')"
if [[ "$BATCH_LINES" -ne 3 ]]; then
    _fail ".batch_files 行數不是 3，實際：$BATCH_LINES"
fi

# .batch_files 內容應是完整路徑，且按 mtime 排序（0001 < 0002 < 0003）。
BATCH_ORDER_OK=1
if ! sed -n '1p' "$BATCH_FILE" | grep -q '0001'; then BATCH_ORDER_OK=0; fi
if ! sed -n '2p' "$BATCH_FILE" | grep -q '0002'; then BATCH_ORDER_OK=0; fi
if ! sed -n '3p' "$BATCH_FILE" | grep -q '0003'; then BATCH_ORDER_OK=0; fi
if [[ "$BATCH_ORDER_OK" -ne 1 ]]; then
    _fail ".batch_files 排序不正確（應按拍攝 mtime 由舊到新）：$(cat "$BATCH_FILE")"
fi

echo "PASS (a): 第一輪匯入 3 檔，.lrv 排除，manifest/.batch_files 正確"

# ---- 執行第二輪 trigger.sh（應無新檔） ----

env \
    GOULTRA_TEST_VOLUME="$FAKE_VOLUME" \
    NTFY_DRYRUN=1 \
    RAW_DEST="$TEST_RAW_DEST" \
    MANIFEST="$TEST_RAW_DEST/.imported_manifest" \
    LOG_DIR="$TEST_LOG_DIR" \
    LOCKFILE="$TEST_LOCKFILE" \
    bash "$REPO_DIR/trigger.sh"
RUN2_STATUS=$?

if [[ "$RUN2_STATUS" -ne 0 ]]; then
    _fail "第二輪 trigger.sh 非零退出碼：$RUN2_STATUS"
fi

IMPORTED_COUNT_AFTER_RUN2="$(find "$DEST_DIR" -type f -iname '*.mp4' | wc -l | tr -d ' ')"
if [[ "$IMPORTED_COUNT_AFTER_RUN2" -ne 3 ]]; then
    _fail "第二輪後目的資料夾檔案數變了（應仍為 3）：$IMPORTED_COUNT_AFTER_RUN2"
fi

MANIFEST_LINES_AFTER_RUN2="$(wc -l < "$MANIFEST_FILE" | tr -d ' ')"
if [[ "$MANIFEST_LINES_AFTER_RUN2" -ne 3 ]]; then
    _fail "第二輪後 manifest 行數變了（應仍為 3）：$MANIFEST_LINES_AFTER_RUN2"
fi

echo "PASS (b): 第二輪匯入 0 新檔，manifest/目的資料夾未變化"

# ---- 驗證 (c)：假卡唯讀鐵律 ----

SNAPSHOT_AFTER="$(_snapshot_volume)"
COUNT_AFTER="$(find "$FAKE_VOLUME" -type f | wc -l | tr -d ' ')"

if [[ "$COUNT_BEFORE" != "$COUNT_AFTER" ]]; then
    _fail "假卡檔案數改變了：before=$COUNT_BEFORE after=$COUNT_AFTER"
fi

if [[ "$SNAPSHOT_BEFORE" != "$SNAPSHOT_AFTER" ]]; then
    _fail "假卡檔案 md5 改變了（唯讀鐵律違反）"
fi

echo "PASS (c): 假卡檔案數與 md5 前後不變（唯讀鐵律成立）"

# ---- 驗證 (d)：log 裡有 dry-run 的 notify 記錄 ----

DRYRUN_LOG_COUNT="$(grep -rl 'DRYRUN notify' "$TEST_LOG_DIR"/run-*.log 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$DRYRUN_LOG_COUNT" -eq 0 ]]; then
    _fail "log 目錄裡找不到 DRYRUN notify 記錄"
fi

echo "PASS (d): log 內含 dry-run notify 記錄（共 $DRYRUN_LOG_COUNT 份 log 檔含記錄）"

echo "ALL PASS"
exit 0

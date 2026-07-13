#!/usr/bin/env bash
# config.sh — 集中設定，供其他 script `source` 使用。
#
# 使用方式：
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
#
# 所有變數皆可被外部環境變數覆寫（`: "${VAR:=default}"` 寫法），
# 方便測試（見 test/fake-mount.sh）在不動到本檔的情況下注入測試值。

# ---- 路徑設定 ----

: "${RAW_DEST:=/Users/saber/03_FCPX/Insta360_RAW}"
: "${MANIFEST:=$RAW_DEST/.imported_manifest}"
: "${LOG_DIR:=$HOME/Library/Logs/goultra-autopilot}"

# Phase 2（headless 剪輯）會用到，Phase 1 先放著。
: "${CLAUDE_BIN:=$HOME/.local/bin/claude}"
: "${MUSIC_FALLBACK_DIR:=/Users/saber/03_FCPX/Music}"

# ---- ntfy 通知設定 ----

: "${NTFY_SERVER:=https://ntfy.sh}"
: "${NTFY_TOPIC:=saber-goultra-8509a1d2}"

# NTFY_DRYRUN=1 時，notify() 只寫 log、不真的 curl 出去（測試用）。
: "${NTFY_DRYRUN:=0}"

# ---- Go Ultra 磁碟辨識設定 ----

# 磁碟名稱 glob pattern（用於 /Volumes/* 掃描時比對）。
# 真實簽名待第一次插卡時校準，屆時把觀察到的實際磁碟名稱更新到這裡並記錄在
# README 的「除錯」段落或 PLAN.md 的 changelog。
: "${GOULTRA_NAME_PATTERN:=*Insta360*}"

# 測試 hook：若有設定，trigger.sh 會直接把此路徑當成「找到的 Go Ultra 卷」使用，
# 跳過 /Volumes 掃描。測試時搭配一個假的卡目錄結構（見 test/fake-mount.sh）。
: "${GOULTRA_TEST_VOLUME:=}"

# ---- lockfile ----

: "${LOCKFILE:=/tmp/goultra-autopilot.lock}"

export RAW_DEST MANIFEST LOG_DIR CLAUDE_BIN MUSIC_FALLBACK_DIR
export NTFY_SERVER NTFY_TOPIC NTFY_DRYRUN
export GOULTRA_NAME_PATTERN GOULTRA_TEST_VOLUME
export LOCKFILE

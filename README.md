# goultra-autopilot

插入 Insta360 Go Ultra 到 Mac 時，自動辨識磁碟、匯入新素材、推播通知手機。
目前完成 **Phase 1（觸發＋匯入＋通知，純 shell）**；Phase 2（headless AI 剪輯）尚未實作，
見 `PLAN.md`。

## 架構

```
插入 Go Ultra
   │ launchd StartOnMount
   ▼
trigger.sh ── 辨識磁碟／不是 Go Ultra 就靜默退出
   │ lockfile 防重入；caffeinate 防睡眠
   ▼
ingest.sh ── 比對 manifest，rsync 新檔 → 03_FCPX/Insta360_RAW/<日期>/
   │ 永不動記憶卡上原檔；推播「匯入 N 支素材」
   ▼
（Phase 2 尚未啟用：目前只推播 stub 通知）
```

## 安裝

```bash
cd /Users/saber/03_GitHub/goultra-autopilot
./install.sh
```

會做的事：
1. 檢查依賴（curl / rsync / caffeinate；`claude` CLI 缺了只警告，Phase 1 不受影響）。
2. 建立 `RAW_DEST`（`/Users/saber/03_FCPX/Insta360_RAW`）與 log 目錄
   （`~/Library/Logs/goultra-autopilot`）。
3. 產生 `com.saber.goultra.plist`（把 `__REPO_DIR__` / `__LOG_DIR__` 占位字串替換成實際路徑）
   並複製到 `~/Library/LaunchAgents/`。
4. `launchctl bootstrap gui/$(id -u)` 載入（若已裝過會先 bootout 舊的）。
5. 發一則真實 ntfy 測試通知，確認手機通知鏈路正常。

## 卸載

```bash
./install.sh uninstall
```

會 `launchctl bootout` 並移除 `~/Library/LaunchAgents/com.saber.goultra.plist`。

## 手動觸發（不插卡也能測）

```bash
# 用真實已掛載的磁碟路徑手動跑一次
bash trigger.sh
# GOULTRA_TEST_VOLUME 會讓 trigger.sh 略過 /Volumes 掃描，直接把該路徑當成 Go Ultra 卡
GOULTRA_TEST_VOLUME=/path/to/fake_or_real_volume bash trigger.sh
```

## 手機 ntfy 訂閱步驟

1. 手機安裝 [ntfy](https://ntfy.sh/) app（App Store / Google Play 搜尋 `ntfy`）。
2. 開 app → 右下角「+」訂閱 topic：`saber-goultra-8509a1d2`
   （注意：ntfy 的 topic 只要知道名稱任何人都能訂閱/發送，這裡用一串隨機字尾當作簡易私有化，
   不要把這個 topic 名稱公開分享）。
3. 訂閱後即可收到匯入完成、無新素材、失敗等通知。

## Log 位置

- 每次 `trigger.sh` 執行會產生一份 `~/Library/Logs/goultra-autopilot/run-YYYYmmdd-HHMMSS.log`，
  包含完整 stdout/stderr 與每則 notify 呼叫的結果（成功/失敗/dry-run）。
- launchd 本身的標準輸出/錯誤額外導向：
  `~/Library/Logs/goultra-autopilot/launchd-stdout.log`、`launchd-stderr.log`。

## 常見除錯

| 症狀 | 排查方法 |
|---|---|
| 插卡沒反應 | `launchctl print gui/$(id -u)/com.saber.goultra` 確認已載入；檢查 `launchd-stderr.log` |
| 一直沒收到通知 | 手機 ntfy app 確認已訂閱 `saber-goultra-8509a1d2`；查最新 `run-*.log` 裡的 `notify` 那幾行是否 `notify OK` |
| 插卡但沒被辨識成 Go Ultra | 檢查 `config.sh` 的 `GOULTRA_NAME_PATTERN`（磁碟名 glob）是否符合實際磁碟名稱；第一次插卡時把觀察到的磁碟名稱記錄下來並更新此設定 |
| 重複匯入同一批素材 | 檢查 `$RAW_DEST/.imported_manifest` 是否存在且未被誤刪；manifest 比對鍵是「檔名\|大小\|mtime」三者全同才算已匯入 |
| 懷疑卡上原始檔案被動過 | ingest.sh 只用 `rsync`（未加 `--remove-source-files` 等會動到來源的選項）；可用 `md5` 抽查卡上檔案確認 |
| 想暫停自動觸發 | `launchctl bootout gui/$(id -u)/com.saber.goultra`（之後要恢復用 `./install.sh` 重裝） |

## 測試

```bash
bash test/fake-mount.sh
```

會在系統暫存目錄建立一個假的 Go Ultra 卷（3 支假 mp4＋1 支 `.lrv`），
以 `NTFY_DRYRUN=1`＋隔離的 `RAW_DEST`/`LOG_DIR` 跑兩輪 `trigger.sh`，斷言：

- 第一輪匯入恰好 3 檔（`.lrv` 被排除），目的資料夾/manifest/`.batch_files` 正確。
- 第二輪匯入 0 新檔（無新素材路徑）。
- 假卡上所有檔案的 md5 與檔案數，前後完全不變（唯讀鐵律）。
- log 內含 dry-run 的 notify 記錄。

全部通過印出 `ALL PASS`；不會碰到真實的 `/Users/saber/03_FCPX/Insta360_RAW`。

## 已知限制 / 待辦

- `GOULTRA_NAME_PATTERN`（磁碟名 glob）是先驗設定，尚未經過真實插卡校準，
  第一次插卡後應更新 `config.sh` 並記錄實際磁碟名稱。
- Phase 2（headless AI 剪輯：留言解析、自動剪輯、BGM、字幕、export、verifier 驗收）尚未實作，
  目前 `trigger.sh` 在匯入成功後只會推播一則「Phase 2 尚未啟用」的說明通知。
- 本機沒有安裝 `shellcheck`，所有 script 僅以 `bash -n` 做語法檢查，未跑 shellcheck lint。

# GoUltra Autopilot — 完整建置計畫

> 2026-07-13 起草。目標：插入 Insta360 Go Ultra 到這台 Mac，即自動匯入素材、
> headless 執行 /edit-video 剪出成片（BGM 由 /suno-bgm 生成），全程不開螢幕不碰鍵盤，
> 進度推播到 Saber 手機。
> 本檔是開發工作檔：方向確認後開 repo，開發決策與踩坑記錄持續寫回本檔（之後移入 repo）。

## 0. 成功標準（整案驗收條件）

1. 實際插入 Go Ultra（不碰鍵盤滑鼠），30 秒內手機收到「偵測到 Go Ultra，開始匯入」推播。
2. 素材自動匯入 `03_FCPX/Insta360_RAW/<日期>/`，記憶卡上原檔完好未刪，重複插拔不會重跑。
3. 自動找出最後一支 mp4 的語音留言，剪輯指示被解析並實際反映在成片中。
4. 成片走完 edit-video skill 完整 checklist（含 export ffprobe 驗證），BGM 為 suno-cli 現場生成或庫存曲（通知中註明是哪種）。
5. 每個里程碑手機都收到推播；交付通知含 3 張抽查截圖可在手機目視驗收。
6. 任一環節失敗時，手機收到「卡在哪＋已嘗試什麼＋建議選項」的通知，而不是無聲死掉。

## 1. 架構總覽

```
插入 Go Ultra
   │ (macOS launchd StartOnMount)
   ▼
trigger.sh ── 不是 Go Ultra？→ 靜默退出
   │ lockfile 防重入；caffeinate 防睡眠
   ▼
ingest.sh ── 比對 manifest，rsync 新檔 → 03_FCPX/Insta360_RAW/<日期>/
   │ 永不刪卡上原檔；推播「匯入 N 支素材」
   │ 無新素材 → 推播後結束（插卡充電不誤觸發剪輯）
   ▼
claude -p（headless，工作目錄 03_FCPX，專用權限 profile）
   ├─ 1. 找最後一支 mp4 → whisper 轉錄語音留言 → 解析剪輯指示（該檔排除於素材外）
   ├─ 2. 照 /edit-video skill 全流程剪輯（建 cutlist 工作檔、派 subagent 盤點）
   ├─ 3. 照 /suno-bgm 用素材總腳本生成 BGM（失敗 fallback：/Users/saber/03_FCPX/Music/ 庫存曲）
   ├─ 4. export → 派 verifier 驗收（ffprobe＋抽 3 時間點截圖）
   └─ 全程：每個里程碑推播；需人決策時推高優先級通知
   ▼
交付推播：成片路徑＋規格＋3 張截圖（手機遠端目視驗收）
```

## 2. 元件細節

### 2.1 觸發：LaunchAgent（StartOnMount）

- `~/Library/LaunchAgents/com.saber.goultra.plist`，`StartOnMount: true`。
  任何磁碟掛載都會執行 `trigger.sh`，由 script 自行判斷是否為 Go Ultra。
- Go Ultra 辨識：檢查 `/Volumes/*` 下的磁碟名稱與 `DCIM/` 目錄結構
  （實際簽名待第一次插卡時確認，寫進 config）。
- 防重入：`/tmp` lockfile（含 PID 檢查，殘留鎖自動清除）。
- 整段流程包在 `caffeinate -i` 裡，防止剪輯中途 Mac 睡著。
- 限制（無法繞過）：插卡當下 Mac 必須是醒著的。建議常態接電＋設定不自動睡眠。

### 2.2 匯入：ingest.sh（純 shell，不進 AI）

- Manifest（`Insta360_RAW/.imported_manifest`，記檔名＋大小＋mtime）比對，只 rsync 新檔。
- rsync `--checksum` 完成後逐檔驗 size，才寫入 manifest。
- **鐵律：只讀不寫記憶卡，永不刪除、永不搬移卡上檔案**（不可逆操作不自動化）。
- 匯入完成推播第一則通知，然後才啟動 claude headless session。

### 2.3 語音留言協議（最後一支 mp4）

- 定義：按**拍攝時間**排序的最後一支 mp4 = 留言檔。whisper 轉錄，解析剪輯指示
  （要收哪些精采片段、哪些對話、長度要求等）。
- 留言檔本身**排除在剪輯素材之外**（不會出現在成片）。
- 判定為留言的條件：轉錄內容含對剪輯的指示語（對 Claude 說話）。若最後一支
  聽起來是一般素材（現場環境音、正常對話）→ 視為無留言，照 skill 預設風格全自動剪，
  並在推播中註明「未偵測到留言，採預設風格」。
- 留言指示與 skill 規則衝突時：留言優先（它更新、更具體），衝突點在交付通知中註明。

### 2.4 Headless 剪輯 session

- 指令形態：`claude -p "$(cat prompt-template.md)" --settings <專用profile> ...`，
  工作目錄 `03_FCPX`（讓專案記憶自動載入）。
- prompt 模板要點（完整內容在 repo 的 `prompt-template.md`）：
  - 開工先全文讀 `~/.claude/commands/edit-video.md` 當 checklist（制度既有規則）。
  - 建 `<案名>_cutlist.md` 工作檔，所有決策落檔（防長 session 被 summarization 後失憶）。
  - 素材盤點、逐段檢查派 subagent（model-dispatch.md 調度規則照舊適用）。
  - 交付前派 verifier，驗收全過才推「完成」通知。
  - **里程碑推播清單**（寫死在 prompt）：留言解析結果 → 盤點完成 → 粗剪完成 →
    BGM 完成 → 字幕/overlay 完成 → export＋驗收結果（附截圖）。
  - 失敗處理：任何環節兩輪升級重試仍失敗（judgment-rubrics 既有規則）→ 推高優先級
    通知說明現況＋選項，結束 session，不硬剪。
- 前置條件檢查（prompt 開頭）：PalmierPro 是否在執行（不在就 `open -a` 拉起再等 MCP 就緒）。

### 2.5 權限設計（不裸奔）

- 專用 settings profile（repo 內 `headless-settings.json`）＋ `--allowedTools` 白名單：
  Palmier MCP 全套、Bash（ffmpeg/ffprobe/whisper/curl/rsync 等既有工作流指令）、
  Read/Write/Edit（限 03_FCPX 與 scratchpad）、Agent、Skill。
- 不用 `--dangerously-skip-permissions`。白名單以一次真實 dry-run 的實際需求為準校調
  （寧可第一次多擋幾下，從 log 補白名單）。

### 2.6 進度通知（雙通道）

查證結果（官方文件，2026-04 起）：Claude Code **有內建手機推播**——Remote Control
＋ Claude mobile app，PushNotification 工具在 headless 模式可用。限制：**純文字、
≤200 字元、無圖片**；需 claude.ai 登入（OAuth）＋ Pro/Max 訂閱＋手機裝 Claude app。

設計：**內建推播負責「叫你」，ntfy 負責「給你看」**——

| 通道 | 用途 | 設定成本 |
|---|---|---|
| 內建 PushNotification | 里程碑一句話通知、需決策的高優先級呼叫 | 零（已有 Claude app 即可，`/config` 開啟） |
| ntfy.sh（私有 topic） | 交付截圖×3、ffprobe 規格、失敗時的詳細現場 | 手機裝 ntfy app 訂閱一個 topic，5 分鐘 |

- 額外紅利：Remote Control 讓你能**從手機回覆** headless session——遇到「該問使用者」
  的情境，你在手機上直接回答，流程不中斷。
- 若想極簡：可以只用內建推播，代價是手機上看不到截圖，遠端目視驗收（成功標準 #5）做不到。
  計畫按雙通道走。
- shell 層（trigger/ingest 階段，還沒進 Claude）統一走 ntfy（一行 curl）。

## 3. 風險與實測清單（按驗證順序）

| # | 風險 | 驗證方法 | fallback |
|---|---|---|---|
| 1 | **Suno 瀏覽器自動化在螢幕鎖定下能不能跑**（全鏈最脆弱） | 鎖屏狀態手動跑一次 suno-cli | 用 /Users/saber/03_FCPX/Music/ 庫存曲，推播註明 |
| 2 | PalmierPro 沒開時 MCP 能否使用 | 關 app 跑一次 headless 測試 | script 先 `open -a PalmierPro` 再等就緒 |
| 3 | PushNotification 在本機 headless 實測（文件說可以，未實測） | `claude -p` 跑一句 PushNotification | 全部改走 ntfy |
| 4 | Go Ultra 掛載簽名（磁碟名/結構） | 第一次插卡時記錄 | — |
| 5 | Mac 睡眠/鎖屏下 USB 掛載與 launchd 行為 | 鎖屏插卡實測 | 設定接電不睡眠 |
| 6 | headless session 中途 crash → 無聲死掉 | 故意 kill 測試 | trigger.sh 監控 claude 退出碼，非零就推失敗通知（外層兜底） |
| 7 | Token 成本：全自動剪輯一次估數十萬 token（含素材 inspect 畫格圖） | 第一次端到端跑完記錄實際用量 | 可接受性由 Saber 判斷；盤點已按制度派 subagent 壓縮主 context |

## 4. Repo 結構（建議名：`goultra-autopilot`，放 03_GitHub）

```
goultra-autopilot/
├── README.md                  # 安裝、卸載、手動觸發、除錯
├── install.sh                 # 裝 LaunchAgent＋檢查依賴（ntfy topic、whisper、claude CLI）
├── com.saber.goultra.plist    # LaunchAgent（StartOnMount）
├── trigger.sh                 # 辨識 Go Ultra、lockfile、caffeinate、外層失敗兜底
├── ingest.sh                  # manifest 比對、rsync、匯入通知
├── notify.sh                  # 通知函式庫（ntfy curl 封裝，shell 層用）
├── prompt-template.md         # headless 剪輯任務 prompt（含里程碑推播清單）
├── headless-settings.json     # 專用權限 profile
├── config.sh                  # 路徑、磁碟簽名、ntfy topic 等集中設定
└── test/
    ├── fake-mount.sh          # 假掛載模擬（建一個假 Go Ultra 目錄結構觸發全流程）
    └── sample-message.mp4     # 測試用留言檔（之後錄）
```

## 5. 分階段建置（每階段獨立可驗收）

**Phase 1 — 觸發＋匯入＋通知**（不碰 AI，純 shell）
- 建 repo、寫 plist/trigger/ingest/notify、設 ntfy topic。
- 驗收：`fake-mount.sh` 模擬掛載 → 手機收到通知、檔案正確匯入、重跑不重複、
  假卡上檔案未被動過。真插卡一次記錄磁碟簽名（風險 #4、#5 一併驗）。

**Phase 2 — headless 剪輯（先小後大）**
- 寫 prompt-template＋headless-settings；風險 #1、#2、#3 逐項實測。
- 先跑「迷你任務」（3 支短素材＋一支留言檔）端到端，校調權限白名單。
- 驗收：迷你成片過 edit-video checklist；留言指示反映在成片；里程碑推播齊全。

**Phase 3 — 真實端到端**
- 你真的去跑一次步，回來插卡，全程不碰電腦。
- 驗收：成功標準 #1–#6 逐條過；記錄實際 token 用量與耗時，回填本檔。

**Phase 4（過完 Phase 3 再說）— 加值項**
- Garmin overlay 自動化（garmin-gpx skill 已有 token 快取，可併入 prompt 流程）、
  剪輯風格記憶回饋迴路（每次交付後你的修改意見寫回記憶）。

## 6. 替你做掉的決策（有異議推翻即可）

1. **插卡＝就剪**：只要有新素材就啟動剪輯（你的原始需求）。「插卡只想充電/備份」
   的情境靠「無新素材就只匯入」cover；若之後發現誤觸發多，再改成「有留言才剪」。
2. **留言優先於 skill 預設**：兩者衝突時聽留言的，衝突點在交付通知註明。
3. **BGM 預設現場生成**：suno-cli 失敗（鎖屏/未登入/改版）自動 fallback 庫存曲，不中斷主流程。
4. **原檔絕不自動刪**：卡的清理永遠是你手動做。
5. **雙通道通知**：內建推播＋ntfy 並用（理由見 2.6）。

## 7. 開放問題（2026-07-14 Saber 已全部回覆）

1. Mac 常態接電＋不睡眠 → **確認**，風險 #5 前提成立。
2. 有 Pro/Max 訂閱，但**手機尚未裝 Claude app** → 內建推播暫時到不了手機；
   ntfy 為現階段唯一手機通道。Saber 裝好 Claude app＋允許通知後，內建推播自動生效。
3. 留言沒講到的參數照 edit-video skill 預設 → **確認**。

## 8. 環境定案（開工時落定的事實）

- Repo：https://github.com/SaberHuang/goultra-autopilot（clone 於 03_GitHub/goultra-autopilot）
- ntfy topic：`saber-goultra-8509a1d2`（私有，Saber 手機 ntfy app 需訂閱此 topic）
- BGM 庫存曲目錄：/Users/saber/03_FCPX/Music/（已確認存在、有多首 mp3）

## Changelog

- 2026-07-13：初版計畫（方向討論後、開工前）。
- 2026-07-14：Saber 確認開放問題；BGM fallback 改為 03_FCPX/Music；記錄 repo 與 ntfy topic；開工 Phase 1。

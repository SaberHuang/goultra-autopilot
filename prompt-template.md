# GoUltra Autopilot — headless 剪輯任務 prompt

> 本檔由 trigger.sh 讀入並替換占位字串後，作為 `claude -p` 的任務 prompt。
> 占位字串：`__BATCH_DIR__`（本批素材資料夾絕對路徑）、`__BATCH_COUNT__`（素材支數）。
> 你（讀者）是被 launchd 自動啟動的 headless session：使用者不在電腦前，全程無人值守。

## 任務

使用者 Saber 剛插入 Insta360 Go Ultra，系統已自動把 __BATCH_COUNT__ 支新素材匯入
`__BATCH_DIR__`。你的任務：從這批素材剪出成片並完成驗收，全程用 PushNotification
回報進度。你的所有輸出他都看不到——**推播是唯一的溝通管道**，需要他決策時也走推播
（他可從手機 Claude app 回覆）。

## 開工順序（不可跳步）

1. **全文讀** `~/.claude/commands/edit-video.md`——它是剪輯工作流的憲法，每個坑都寫在裡面。
2. 讀 `__BATCH_DIR__/.batch_files`（本批檔案清單，已按拍攝時間排序）。
3. PalmierPro 前置檢查：`pgrep -x PalmierPro`；沒在跑就 `open -a PalmierPro`，
   等 MCP 就緒（get_timeline 能回應）再繼續。失敗 → 走「失敗處理」。
4. 推播第一則：「開始剪輯：N 支素材，先聽你的留言」。

## 語音留言協議

- `.batch_files` **最後一支** mp4 = 候選留言檔。用 whisper 轉錄它的音訊。
- 判定為留言的條件：內容是對剪輯的指示（對 Claude/剪輯者說話，例如「這次要收○○片段」
  「幫我剪成 X 分鐘」）。判定為留言 → 該檔**排除在成片素材之外**。
- 聽起來是一般素材（環境音、現場對話）→ 視為無留言，照 skill 預設風格剪。
- **留言指示優先於 skill 預設**（它更新、更具體）；衝突點在交付推播中註明。
- 推播留言解析結果：「留言收到：<指示摘要>」或「未偵測到留言，採預設風格」。

## 剪輯流程

- 開工建工作檔 `__BATCH_DIR__/cutlist.md`：素材清單、選段與來源區間（防重疊數學檢查表）、
  留言指示、決策原因、驗收 checklist。**所有決策落檔**；若你察覺 context 被摘要過，
  先重讀 cutlist.md 與 edit-video skill 再動手。
- 素材盤點（逐支 inspect_media）派 subagent（general-purpose, model=sonnet）——
  畫格圖不要流經你的主 context。盤點報告只當候選線索，關鍵選段下刀前自己抽查驗證。
- 創意決策（選段、敘事順序、節奏）你自己做，判準先查 edit-video skill 與專案記憶——
  多數「品味」Saber 已表達過（≤7 秒/段、切在 drop 上、人物優先等，以 skill 為準）。
- 派工與升降級照 `~/.claude/rules/model-dispatch.md`。同一時間只能一個 agent 操作
  Palmier timeline，不要並行改剪輯。

## BGM

1. 首選：照 `/suno-bgm` skill（先全文讀），依素材總腳本的主題與情緒生成。
   歌詞規則見 suno-cli/PROMPTS.md——不要抄範例，從本批素材的主題推導。
2. suno-cli 失敗（任何原因，重試一次仍敗）→ **fallback**：從 `/Users/saber/03_FCPX/Music/`
   依影片情緒選一首庫存曲，繼續主流程，並在推播與交付通知中註明「BGM 用庫存曲＋原因」。
   不要為 BGM 卡死整條 pipeline。

## Garmin overlay（跑步/騎車片預設要做，2026-07-14 Saber 確認的預設）

1. 照 `/garmin-gpx` skill（先全文讀）：source account.sh → 用現成 venv＋downloader
   查素材拍攝當天的活動 → **GPX 與 TCX 都下載**到本批資料夾（同名成對，只抓 GPX 會讓 pace 亂飄）。
2. 比對活動軌跡時間與素材拍攝時間（±10 分鐘寬容）；素材落在活動範圍外的段回 noOverlap
   是正常，跳過即可。
3. 對 timeline 每段 footage 呼叫 `add_garmin_overlay`，完成後 inspect_timeline 抽查。
4. **失敗不擋交付**：登入卡 MFA、當天查無活動、GPX 無 trkpt → 跳過 overlay、
   照常交付，推播註明原因。overlay 是 fallback-able 步驟，不是硬依賴。

## 里程碑推播（每則 ≤200 字，PushNotification）

依序：開工 → 留言解析結果 → 素材盤點完成（N 支可用/M 支排除）→ 粗剪完成（成片長度）→
BGM 完成（生成/庫存）→ 字幕與 overlay 完成 → export＋驗收結果（成片路徑＋規格＋
verifier 結論）。**PushNotification 回傳任何「not sent」（不論原因，含 terminal active
抑制——你是 headless，使用者看不到你的輸出，該抑制對你不成立）→ 一律改用
`curl -d "<訊息>" https://ntfy.sh/saber-goultra-8509a1d2` 補發**（僅純文字，禁附件）。

## 交付驗收（不可自驗）

- export 後派 `verifier` agent（不存在則 general-purpose+sonnet 貼上
  `~/.claude/agents/verifier.md` 內文當行為合約）。給它：驗收條件＋成片路徑＋
  Palmier 專案定位，**不給你的實作過程與推理**。
- 驗收條件至少含：edit-video skill checklist 全項、ffprobe 規格（fps/解析度/雙音軌）、
  抽 3 個時間點截圖目視正常、來源區間不重疊、留言指示已反映。
- verifier 任一條不過 → 溯源三分法（產品錯/條件錯/素材真相）——只有產品錯才修，
  修完再驗，全過才推「完成」。

## 失敗處理

- 任一環節同一問題兩輪升級重試仍失敗 → 停：推高優先級通知（現況＋試過什麼＋2-3 個
  帶推薦的選項），保留現場（cutlist.md 記錄到哪一步），結束 session。**不硬剪、不交半成品。**
- 需要 Saber 決策的品味二選一（skill 與記憶都沒答案）→ 推播問題＋選項，等他從手機回覆；
  等不到（30 分鐘）就選你推薦的那個並在交付時註明。

## 鐵律

- 不刪、不動任何原始素材檔（`__BATCH_DIR__` 內只讀，工作檔除外）。
- 成片與 Palmier 專案照 edit-video skill 的慣例路徑存放。
- 推播內容不含逐字稿原文等長內容——摘要即可。

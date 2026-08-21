# agent-gemma（專案藍圖）

> 本檔為跨 Agent 通用的專案藍圖（AGENTS.md 開放標準）。任何 Agent 的每個 session 都應先讀本檔＋`handoff.md`。
> Claude Code 不讀 `agents.md`，改由 `CLAUDE.md` 的 `@agents.md` import 本檔；Claude 專屬規範寫在 `CLAUDE.md`。

## 專案簡介

讓 OpenCode 能呼叫本機的 Google Gemma（透過 Ollama）。核心產出是一支 PowerShell 7 腳本，在一台全新的 Windows 電腦上完成：偵測顯示卡 → 依 VRAM 選出跑得動的 Gemma 版本 → 安裝 Ollama → 下載模型 → 設定上下文長度 → 寫入 `opencode.json` → 實際送訊息驗證。

## 同步層級

| 層級 | 位置 | 用途 |
|------|------|------|
| L1 本地 | `我的雲端硬碟/agents/agent-gemma`（GDrive 同步） | `agents.md` 藍圖＋`handoff.md` 交接＋`CLAUDE.md` 橋接 |
| L2 GitHub | [changyiwu/agent-gemma](https://github.com/changyiwu/agent-gemma)（**公開**） | 版本控制與雲端備份（`handoff.md` 不進 repo） |
| L3 Obsidian | vault 內 `agent-gemma/專案工作流程.md` | 詳細脈絡、決策紀錄、踩坑筆記、更動紀錄 |

## 關鍵時程

目前沒有固定時程。

## 目標與路線圖

- [x] 階段一：確認 Ollama 的 Gemma 4 實際 tag 與大小、OpenCode provider schema、Ollama 上下文預設行為
- [x] 階段二：完成 `setup-gemma.ps1`（硬體偵測、選型表、安裝、拉模型、環境變數、設定合併、煙霧測試）
- [x] 階段三：完成隔離測試 `tests/test-setup-gemma.ps1`（不連網不改系統）
- [x] 階段四：完成 `SKILL.md` 與 README
- [x] 階段五：在 Windows 實機跑完整流程並驗證兩個 VRAM 階層（16GB→131072、8GB→32768，皆 100% GPU）
- [x] 階段六：加入 Apple Silicon macOS 支援；測試擴充到 59 項
- [x] 階段七：專案初始化三層級（L1 本地、L2 公開 GitHub、L3 Obsidian）
- [ ] 階段八：在實體 Mac 上驗證 macOS 路徑（目前只有邏輯與 plist 格式測試，沒有實機跑過）
- [ ] 階段九：驗證 24GB 那階的 MoE 選型（`gemma4:26b-a4b-it-qat` 對比 `31b-it-qat` 的速度與品質）。原本以為要一台 24GB 顯卡的機器，但 **36GB 以上的 Apple Silicon Mac 也能達成**（見下方選型表），可以跟階段八一起做掉
- [x] 階段十：讓腳本處理 `opencode.jsonc`（盤點 `.json`／`.jsonc` 並存、`-Check` 兩份都讀並揪出死項目、寫入前警告重複的 provider 定義）；測試 59 → 72 項
- [x] 階段十一：揪出 Ollama 桌面 app 的 GUI 設定覆蓋 `OLLAMA_CONTEXT_LENGTH`（腳本比對 server log 的實際注入值，不一致就報警並給修法）；測試 72 → 89 項

技能刻意**不**同步到全域技能目錄，見下方「技術決策」。

## 資料夾結構

```text
agent-gemma/
├── .opencode/skills/gemma-setup/   # OpenCode 專案技能（不裝到全域）
│   ├── SKILL.md                    # 觸發條件與 Agent 執行流程
│   └── setup-gemma.ps1             # 偵測、安裝、設定、驗證的主腳本
├── tests/
│   └── test-setup-gemma.ps1
├── agents.md              # 跨 Agent 專案藍圖
├── handoff.md             # 跨工作階段交接（本機檔，git 不追蹤，靠 GDrive 同步）
├── CLAUDE.md              # Claude Code 橋接
├── README.md
├── LICENSE
├── .gitattributes         # 固定文字檔為 LF，避免跨電腦 hash 漂移
└── .gitignore
```

## 技術決策與理由

**為什麼上下文要在兩個地方各設一次**
Ollama 0.30 之後，`OLLAMA_CONTEXT_LENGTH` 未設定時是「依 VRAM 動態決定」：未滿 23 GB 只給 4096，23 GB 以上 32768，47 GB 以上 262144。OpenCode 端的 `limit.context` 只影響 OpenCode 自己怎麼切對話，不會改變 Ollama 實際載入的上下文。兩邊都要設。

**Ollama 桌面 app 的 GUI 設定會覆蓋 `OLLAMA_CONTEXT_LENGTH`（0.32 實測）**
桌面 app 把自己的設定存在 `db.sqlite` 的 `settings.context_length`（Windows 在 `%LOCALAPPDATA%\Ollama\`），**出廠預設 32768**。它啟動 server 時會把這個值當環境變數注入，蓋掉使用者環境變數，而且沒有任何提示。

在 `PC-YI-FY` 上的鐵證：使用者環境變數設成 131072，server log 卻是

```
msg="server config" env="map[... OLLAMA_CONTEXT_LENGTH:32768 ...]"
msg="vram-based default context" total_vram="15.9 GiB" default_num_ctx=4096
```

Ollama 自己依 VRAM 算的是 4096，實際用 32768 —— 那個 32768 只可能來自 GUI。同一台改用 `ollama serve` 直接啟動，注入的就是 131072。

這也解掉了 `NB-YI` 那個「`OLLAMA_CONTEXT_LENGTH` 進場前就已是 32768、來源不明」的謎：**那不是誰設的，是桌面 app 的出廠預設**。

影響很惡劣：腳本每一步都回報成功、`opencode.json` 也寫對了，實際載入的卻是另一個值，而且重開機後又會被蓋一次。所以腳本現在會比對「持久化的環境變數」與「server log 記的實際注入值」，不一致就報警並給修法（見下方 `Test-RuntimeContext`）。

修法有二：把桌面 app 設定裡的 context length 也改成同一個值（一勞永逸），或關掉桌面 app 改用 `ollama serve`。本專案兩台 Windows 機器都採前者。

**判斷「實際生效值」要看 server log，不是環境變數**
`Get-PersistentEnv` 讀到的是「我們希望的值」，`ollama ps` 的 CONTEXT 要模型載入後才有。唯一隨時可查、且反映真實情況的是 server log 每次啟動寫的那行 `server config`。腳本用 `Read-ContextFromLogText` 解析它（抽成吃字串的純函式，才能在沒有 Ollama 的機器上測），由 `Test-RuntimeContext` 做比對。

log 位置：Windows `%LOCALAPPDATA%\Ollama\server*.log`、macOS `~/.ollama/logs/server*.log`。`server.log` 是當前的，`server-1.log` 以後是輪替過的舊檔，所以要由新到舊找第一個讀得到值的檔，並取檔內**最後一次**匹配。同一行還有 `default_num_ctx=4096` 這種誘餌數字，正則必須綁 `OLLAMA_CONTEXT_LENGTH:` 前綴。

**`contextLength` 是無效欄位**
OpenCode 的 `provider.<id>.models.<tag>` schema 只認 `limit: { context, output }`（`required: [context, output]`）。`contextLength` 不在 schema 裡，寫了會被靜默忽略。腳本會主動移除既有設定裡的這個欄位。

**VRAM 怎麼讀**
`Win32_VideoController.AdapterRAM` 是 32-bit 有號整數，超過 4GB 會失真，不能用。NVIDIA 走 `nvidia-smi --query-gpu=memory.total`；其餘讀登錄檔 `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-...}\<n>\HardwareInformation.qwMemorySize`。

**選型表的閾值刻意壓低**
標稱 16GB 的卡實際回報約 15.9 GB，24GB 約 23.6 GB。所以 `MinVram` 用 15 / 23 / 31 / 46，不用整數標稱值。

**16GB 那階的 131072 是實測值，不是估的**
在 RTX 5060 Ti 16GB 上用 `nvidia-smi` 量 `gemma4:12b`：4096 佔 8181 MiB、65536 佔 9550 MiB、131072 佔 10291 MiB、262144 佔 12467 MiB，全程 100% GPU。Gemma 的滑動視窗注意力讓 KV cache 幾乎不隨上下文線性成長，從 4K 到 131K 只多 2.1 GB。取 131072 而非上限，是留約 3.7 GB 給桌面環境波動。8GB 那階也已實測（見下），其餘階層還沒實測，數字偏保守。

**8GB 那階的 32768 也是實測值**
在 RTX 5060 **Laptop** GPU 8GB 上跑 `gemma4:e4b-it-qat`：`ollama ps` 顯示 CONTEXT 32768、100% GPU，載入只佔 3.1 GB，留約 4.9 GB 餘裕。這台同時有 AMD Radeon 610M 內顯（0.5 GB），顯卡篩選規則正確挑到 NVIDIA 那張，沒被內顯干擾。餘裕看起來還能往上調上下文，但沒實測過更高值，維持 32768。

（當時記的「`OLLAMA_CONTEXT_LENGTH` 進場前就已是 32768、來源不明」已經查明是桌面 app 的 GUI 預設值，見上面那一段。這台之所以矇混過關，是因為腳本判定「已是目標值」就沒改也沒重啟 —— 剛好等於 8GB 這階的建議值。）

**16GB 那階的 10291 MiB 已在第二台機器重現**
`PC-YI-FY`（RTX 5060 Ti 16GB）用 `nvidia-smi` 取載入前後差值，131072 下實佔 **10288 MiB**，與桌機首次實測的 10291 MiB 只差 3 MiB。這一階的數字可以當定論用。

量的時候要先確認沒有殘留 —— 殺 `ollama` 與 `ollama app` 不會帶走 `llama-server.exe`，那才是真正吃 VRAM 的行程。漏殺它會讓 baseline 多算幾個 GB（第一次量出 5206 MiB 的差值就是這樣來的，看起來還「比較省」，其實是舊實例已經佔著）。三個名字都要殺：`ollama`、`ollama app`、`llama-server`。

**選型表的「下載大小」不等於顯存佔用**
`gemma4:e4b-it-qat` 下載後 `ollama list` 顯示 6.1 GB，實際載入 `ollama ps` 只佔 3.1 GB。選型表的 `SizeGB` 是**磁碟下載大小**，用來預告要下載多久、要留多少硬碟，不能拿來推算塞不塞得進 VRAM。同理，同名模型的非 QAT 版本（`gemma4:e4b`，9.6 GB）在 8GB 卡上會部分掉到 CPU，QAT 版本才進得去 —— 8GB 這階一定要用 `-it-qat`。

**兩個上下文設定的作用範圍相反**
`opencode.json` 的 `limit.context` 掛在 `provider.ollama.models.<tag>` 底下，只影響那一個模型；`OLLAMA_CONTEXT_LENGTH` 是 Ollama 伺服器的環境變數，**所有**經由 Ollama 跑的模型都吃它。

這代表：日後若在同一台 Ollama 上再拉一個明顯更大的模型（例如 27B），全域的 131072 會讓它配不下而掉層到 CPU，且使用者不會意識到跟 Gemma 的設定有關。屆時的解法是把全域值設保守、個別模型用 Modelfile 拉高：

```
FROM gemma4:12b
PARAMETER num_ctx 16384
```

已實測驗證：這樣 `ollama create` 出來的衍生模型，走 OpenAI 相容端點載入時 `ollama ps` 的 CONTEXT 確實是 16384，蓋過全域設定。這也是 OpenCode 這條路上唯一能做到逐一模型控制上下文的方法（`num_ctx` 從 OpenAI 端點傳不進去，見下）。衍生模型共用權重 blob，不額外佔磁碟。

**`num_ctx` 無法從 OpenAI 相容端點傳入（已實測）**
同一台機器上三個對照：`/v1/chat/completions` 不帶參數 → 載入 4096；`/v1/chat/completions` 帶 `options.num_ctx=32768` → 仍是 4096，被靜默忽略；原生 `/api/chat` 帶同樣參數 → 32768。OpenCode 走 `@ai-sdk/openai-compatible`，打的是前者，所以 `opencode.json` 在協定層面上就無法決定實際載入的上下文，只能靠 `OLLAMA_CONTEXT_LENGTH` 或 Modelfile。

**`ollama ps` 的 SIZE 欄位不可靠**
同一個模型不同上下文下會在 8.1～8.5 GB 之間亂跳，跟實際 VRAM 佔用對不上。要量就用 `nvidia-smi --query-gpu=memory.used` 取載入前後的差值。

**24GB 那階選 MoE**
`gemma4:26b-a4b-it-qat`（16 GB）總參數 26B 但每次只啟用 4B，同顯存下比 31B 密集模型快得多。

**技能放專案層級，不進全域**
路徑是 `.opencode/skills/gemma-setup/` —— OpenCode 對專案技能會從 cwd 往上找到 git worktree 根目錄。刻意不裝進 `~/.config/opencode/skills/`，也不跑 `sync-skills`：這個技能只服務「OpenCode 接本機模型」這一件事，沒有跨專案使用的理由，放全域只會在每個專案的技能清單裡佔位置。

**macOS 只支援 Apple Silicon**
Intel Mac 沒有 Ollama 可用的 GPU 加速（Metal 後端只對 Apple Silicon 有效），純 CPU 跑 12B 不堪用。腳本在 `Get-MacHardware` 用 `uname -m` 檢查，不是 arm64 就直接 throw 並說明原因，而不是讓使用者下載完 7.6GB 才發現跑不動。

**Apple Silicon 的「等效 VRAM」是估的**
統一記憶體由 CPU/GPU 共用，Metal 的可取用上限看 `iogpu.wired_limit_mb`，未調整時約為總記憶體的 65~75%。腳本取保守比例（36GB 以下 70%、以上 80%）換算後套用同一張 GPU 選型表。這是啟發式，不是量測值 —— 真的在 Mac 上跑過之後應該回頭校正。

**Mac 要幾 GB 才選得到 MoE：36GB**
把上面的比例套進 GPU 選型表（MoE 那階門檻是 23）：

| 統一記憶體 | 等效 VRAM | 選到 |
|---|---|---|
| 24 GB | 16.8 | `gemma4:12b` / 131072 |
| 32 GB | 22.4 | `gemma4:12b`（**差 0.6 GB 沒進 MoE**） |
| **36 GB** | 25.2 | **`gemma4:26b-a4b-it-qat`** |
| 48 GB | 38.4 | `gemma4:31b-it-qat`（跳過 MoE） |
| 64 GB | 51.2 | `gemma4:31b-it-q8_0` |

自動選中 MoE 的窗口只有 36–40 GB 這一小段。**32GB 的 Mac 實際上跑得動**（權重 16 GB，32GB 機器的 wired limit 預設約 24 GB），只是被 0.70 的保守比例卡在門檻外 0.6 GB —— 要在 32GB 機器上測就得 `-Model gemma4:26b-a4b-it-qat` 手動指定。48GB 以上想測 MoE 也一樣要手動指定，否則會自動跳到 31B 密集模型。

這個「差 0.6 GB」正是估值不準的代價，也是階段八要校正那個比例的具體理由。

**macOS 的環境變數要做兩層**
`launchctl setenv` 立即生效且 GUI 版 Ollama 讀得到，但**活不過重開機**。所以還要在 `~/Library/LaunchAgents/ai.ollama.env.plist` 寫一個 `RunAtLoad` 的 LaunchAgent 於登入時重設。少了這層，使用者某天重開機後上下文會悄悄掉回 4096，而且完全沒有徵兆 —— 這是最難查的那種故障。`-Check` 會檢查 plist 是否存在。

**必須用 PowerShell 7**
腳本是 UTF-8 無 BOM，5.1 會用系統 ANSI 解讀而在 parse 階段失敗；而且 `ConvertFrom-Json -AsHashtable` 在 5.1 不存在，設定合併會直接壞掉。腳本有 `#requires -Version 7.0`。

**OpenCode 會合併 `opencode.json` 與 `opencode.jsonc`**
兩個檔案同時存在時 OpenCode 兩份都讀、合併生效（已實測：`opencode models ollama` 同時列出兩邊定義的模型）。腳本用 `Resolve-OpenCodeConfig` 盤點同目錄的兩個檔名，`-Check` 逐份回報、並比對 `ollama list` 指出「設定裡有但 Ollama 沒有」的死項目；寫入前若發現另一份也定義了 `provider.ollama`，會警告那份不會被清掉、要手動移除。

寫入目標的規則：明確給 `-ConfigPath` 就寫那份（盤點與警告照做）；沒給時只有 `.jsonc` 存在就寫 `.jsonc`，其餘一律寫 `.json`。

**單一設定檔請用 `.json`，不要用 `.jsonc`**
腳本寫回時走 `ConvertTo-Json`，**註解一定會被清掉** —— `.jsonc` 唯一的優勢因此不成立。腳本寫入 `.jsonc` 時會先警告這件事。PowerShell 7 的 `ConvertFrom-Json` 讀得動註解與尾逗號（5.1 不行，這是另一個必須用 pwsh 7 的理由）。

**設定合併不覆寫整份檔案**
`opencode.json` 裡還有 mcp、permission、experimental 等使用者既有設定。腳本用 `ConvertFrom-Json -AsHashtable` 讀進來、只改 `provider.ollama` 這一支、再寫回，並在寫入前備份成 `opencode.json.bak-<時間戳>`（同一秒重跑會自動加序號，不覆蓋前一份）。

## 測試

```powershell
pwsh -NoProfile -File .\tests\test-setup-gemma.ps1
```

隔離測試 89 項：不連網、不安裝、不下載模型、不動使用者環境變數、不碰真正的 `opencode.json`。做法是用 AST 把腳本裡的函式抽出來單獨定義，避開主流程。涵蓋語法／編碼、Windows 與 Apple Silicon 兩條選型路徑、顯卡篩選規則、LaunchAgent 的 plist 是否為合法 XML、設定合併與備份、`.json`／`.jsonc` 並存時的解析與寫入目標，以及 server log 的上下文解析與不一致偵測。

log 解析那組測試用**假的 log 文字**餵 `Read-ContextFromLogText`，不碰真的檔案；不一致偵測則在區塊內重新定義 `Write-Warn2`／`Get-OllamaRuntimeContext` 之類的相依函式來攔輸出，所以在沒裝 Ollama 的機器上也跑得完。誘餌案例（`default_num_ctx=4096`）刻意保留，避免哪天正則放寬成 `\d+` 又抓錯數字。

macOS 的實際系統呼叫（`launchctl`、`osascript`、`brew`）在 Windows 上測不到，所以把 plist 的 XML 組裝抽成 `New-MacLaunchAgentXml` 獨立函式，至少讓最容易出跳脫錯誤的那段可以被驗證。

## 對外相依

- Ollama（winget id `Ollama.Ollama`）
- Ollama registry 的 `gemma4` / `gemma3` tag
- OpenCode 設定 schema：<https://opencode.ai/config.json>
- OpenCode 的 Ollama 接法需要 `@ai-sdk/openai-compatible`（OpenCode 沒有內建 ollama provider）

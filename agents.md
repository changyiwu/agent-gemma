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
- [x] 階段五：在這台電腦實跑完整流程並驗證（CONTEXT 131072、100% GPU）
- [x] 階段六：加入 Apple Silicon macOS 支援；測試擴充到 59 項
- [x] 階段七：專案初始化三層級（L1 本地、L2 公開 GitHub、L3 Obsidian）
- [ ] 階段八：在實體 Mac 上驗證 macOS 路徑（目前只有邏輯與 plist 格式測試，沒有實機跑過）

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

**`contextLength` 是無效欄位**
OpenCode 的 `provider.<id>.models.<tag>` schema 只認 `limit: { context, output }`（`required: [context, output]`）。`contextLength` 不在 schema 裡，寫了會被靜默忽略。腳本會主動移除既有設定裡的這個欄位。

**VRAM 怎麼讀**
`Win32_VideoController.AdapterRAM` 是 32-bit 有號整數，超過 4GB 會失真，不能用。NVIDIA 走 `nvidia-smi --query-gpu=memory.total`；其餘讀登錄檔 `HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-...}\<n>\HardwareInformation.qwMemorySize`。

**選型表的閾值刻意壓低**
標稱 16GB 的卡實際回報約 15.9 GB，24GB 約 23.6 GB。所以 `MinVram` 用 15 / 23 / 31 / 46，不用整數標稱值。

**16GB 那階的 131072 是實測值，不是估的**
在 RTX 5060 Ti 16GB 上用 `nvidia-smi` 量 `gemma4:12b`：4096 佔 8181 MiB、65536 佔 9550 MiB、131072 佔 10291 MiB、262144 佔 12467 MiB，全程 100% GPU。Gemma 的滑動視窗注意力讓 KV cache 幾乎不隨上下文線性成長，從 4K 到 131K 只多 2.1 GB。取 131072 而非上限，是留約 3.7 GB 給桌面環境波動。其他 VRAM 階層還沒實測，數字偏保守。

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

**macOS 的環境變數要做兩層**
`launchctl setenv` 立即生效且 GUI 版 Ollama 讀得到，但**活不過重開機**。所以還要在 `~/Library/LaunchAgents/ai.ollama.env.plist` 寫一個 `RunAtLoad` 的 LaunchAgent 於登入時重設。少了這層，使用者某天重開機後上下文會悄悄掉回 4096，而且完全沒有徵兆 —— 這是最難查的那種故障。`-Check` 會檢查 plist 是否存在。

**必須用 PowerShell 7**
腳本是 UTF-8 無 BOM，5.1 會用系統 ANSI 解讀而在 parse 階段失敗；而且 `ConvertFrom-Json -AsHashtable` 在 5.1 不存在，設定合併會直接壞掉。腳本有 `#requires -Version 7.0`。

**設定合併不覆寫整份檔案**
`opencode.json` 裡還有 mcp、permission、experimental 等使用者既有設定。腳本用 `ConvertFrom-Json -AsHashtable` 讀進來、只改 `provider.ollama` 這一支、再寫回，並在寫入前備份成 `opencode.json.bak-<時間戳>`（同一秒重跑會自動加序號，不覆蓋前一份）。

## 測試

```powershell
pwsh -NoProfile -File .\tests\test-setup-gemma.ps1
```

隔離測試 59 項：不連網、不安裝、不下載模型、不動使用者環境變數、不碰真正的 `opencode.json`。做法是用 AST 把腳本裡的函式抽出來單獨定義，避開主流程。涵蓋語法／編碼、Windows 與 Apple Silicon 兩條選型路徑、顯卡篩選規則、LaunchAgent 的 plist 是否為合法 XML、設定合併與備份。

macOS 的實際系統呼叫（`launchctl`、`osascript`、`brew`）在 Windows 上測不到，所以把 plist 的 XML 組裝抽成 `New-MacLaunchAgentXml` 獨立函式，至少讓最容易出跳脫錯誤的那段可以被驗證。

## 對外相依

- Ollama（winget id `Ollama.Ollama`）
- Ollama registry 的 `gemma4` / `gemma3` tag
- OpenCode 設定 schema：<https://opencode.ai/config.json>
- OpenCode 的 Ollama 接法需要 `@ai-sdk/openai-compatible`（OpenCode 沒有內建 ollama provider）

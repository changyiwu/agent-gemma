# agent-gemma

在新電腦上，一行指令把「OpenCode 呼叫本機 Gemma」設定到能用。

透過 [Ollama](https://ollama.com) 跑 Google 的 Gemma 模型，依顯示卡自動選版本、設定上下文長度，並寫進 OpenCode 設定。

## 快速開始

在本專案根目錄開 PowerShell 7（Windows 用 `pwsh`，macOS 先 `brew install --cask powershell`）：

```powershell
pwsh -NoProfile -File ./.opencode/skills/gemma-setup/setup-gemma.ps1 -Plan
```

先看它偵測到什麼、打算裝哪個版本。確認沒問題再跑正式設定：

```powershell
pwsh -NoProfile -File ./.opencode/skills/gemma-setup/setup-gemma.ps1
```

每個會改動系統的步驟（安裝 Ollama、下載模型、設定環境變數、建立 LaunchAgent、覆寫 `opencode.json`）都會先問一次。

跑完直接在 OpenCode 裡用 `/models` 選 **Ollama (local)** 底下的模型即可。上下文是由 Ollama 伺服器決定的，腳本已經重啟它並套用設定，不需要重開終端機。

## 支援的平台

| 平台 | 加速方式 | 狀態 |
|------|---------|------|
| Windows + NVIDIA 獨顯 | CUDA | 已在 RTX 5060 Ti 16GB 實測 |
| Windows + AMD 獨顯 | ROCm | 支援，但 Ollama 只認部分 gfx 型號 |
| macOS + Apple Silicon | Metal（統一記憶體） | 已實作，**尚未在實機驗證** |
| macOS + Intel | 無 | 不支援，腳本會擋掉並說明原因 |

Intel Mac 沒有 Ollama 可用的 GPU 加速，純 CPU 跑 12B 不堪用，所以直接擋掉而不是讓你等半天才發現。

## 它做了什麼

| 步驟 | Windows | macOS（Apple Silicon） |
|------|---------|----------------------|
| 1. 偵測硬體 | NVIDIA 走 `nvidia-smi`；其餘讀登錄檔的 `qwMemorySize`。內顯會被排除 | `uname -m` 確認 arm64，`sysctl hw.memsize` 讀統一記憶體 |
| 2. 選版本 | 依可用 VRAM 對照選型表 | 依統一記憶體的可用比例對照同一張表 |
| 3. 安裝 Ollama | `winget install Ollama.Ollama`；沒有 winget 就用官方安裝檔 | `brew install --cask ollama` |
| 4. 下載模型 | `ollama pull`，已存在就跳過 | 同左 |
| 5. 設定上下文 | 設使用者環境變數 | `launchctl setenv` ＋ 寫 LaunchAgent 讓它活過重開機 |
| 6. 重啟 Ollama | 結束行程後重開 `ollama app.exe` | `osascript` 結束 App 後 `open -a Ollama` |
| 7. 寫 OpenCode 設定 | 合併進 `~/.config/opencode/opencode.json`（先自動備份，保留既有的 mcp／permission 等設定） | 同左 |
| 8. 驗證 | 送一則訊息到 `/v1/chat/completions`，並印出 `ollama ps` 的實際載入狀態 | 同左 |

`Win32_VideoController.AdapterRAM` 是 32-bit 有號整數，超過 4GB 會失真，所以 Windows 這邊不用它。

## 選型表

| VRAM | 模型 | 下載大小 | 上下文 |
|------|------|---------|--------|
| 48 GB+ | `gemma4:31b-it-q8_0` | 34 GB | 131072 |
| 32 GB | `gemma4:31b-it-qat` | 19 GB | 65536 |
| 24 GB | `gemma4:26b-a4b-it-qat` | 16 GB | 32768 |
| 16 GB | `gemma4:12b` | 7.6 GB | 131072 |
| 10–12 GB | `gemma4:12b` | 7.6 GB | 32768 |
| 8 GB | `gemma4:e4b-it-qat` | 6.1 GB | 32768 |
| ≤ 6 GB | `gemma4:e2b-it-qat` | 4.3 GB | 16384 |

沒有 Ollama 可用的獨立顯卡時，改依系統記憶體走 CPU 路徑（很慢，只建議拿來確認流程能通）。

`24 GB` 那階刻意選 MoE 的 `26b-a4b`：總參數 26B 但每次只啟用 4B，同樣顯存下比 31B 密集模型快得多。

**31B 是 Gemma 4 的天花板**，沒有更大的參數量。表上每個尺寸只收了 qat 與 q8_0 兩階，registry 上還有中間與更高的精度 —— 31B 是 qat 19 GB / q4_K_M 20 GB / mxfp8 33 GB / q8_0 34 GB / bf16 63 GB，26B MoE 是 16 / 18 / 28 / 28 / 52 GB。另有 coding 專用的 `gemma4:31b-coding-mtp-bf16`（64 GB）。要用這些就 `-Model` 手動指定。

### Apple Silicon 怎麼換算

M 系列是統一記憶體，CPU 和 GPU 共用同一塊。Metal 能取用的上限由 `iogpu.wired_limit_mb` 決定，未調整時大約是總記憶體的 65～75%。腳本取保守值換算成「等效 VRAM」後，套用上面同一張表：

| 統一記憶體 | 取用比例 | 等效可用 | 選到的模型 | 上下文 |
|-----------|---------|---------|-----------|--------|
| 8 GB | 70% | 5.6 GB | `gemma4:e2b-it-qat` | 16384 |
| 16 GB | 70% | 11.2 GB | `gemma4:12b` | 32768 |
| 24 GB | 70% | 16.8 GB | `gemma4:12b` | 131072 |
| 32 GB | 70% | 22.4 GB | `gemma4:12b` | 131072 |
| 36 GB | 70% | 25.2 GB | `gemma4:26b-a4b-it-qat` | 32768 |
| 48 GB | 80% | 38.4 GB | `gemma4:31b-it-qat` | 65536 |
| 64 GB | 80% | 51.2 GB | `gemma4:31b-it-q8_0` | 131072 |

寧可低估也不要載到一半才發現爆掉。覺得太保守就用 `-Context` 或 `-Model` 自己指定。

> ⚠️ **Mac 路徑尚未實機驗證**，上表的比例是保守估計。另外 Ollama 在 Apple Silicon 是 GGUF／MLX **雙後端** —— GGUF 走 llama.cpp ＋ Metal，`-mlx` tag 才走 Apple 的 MLX 引擎，不會自動互轉。本腳本一律選 GGUF tag，所以走的是 Metal 那條路。MLX 版官方宣稱更快更省記憶體，但本專案沒有實測，也還沒確認 MLX 的「32 GB 以上統一記憶體」門檻在新版是否仍然存在。

**想跑 26B MoE 的話，自動選型的窗口只有 36–40 GB**：32 GB 差 0.6 GB 沒跨過門檻（實際上跑得動，權重才 16 GB），48 GB 以上則會跳到 31B 密集模型。這兩種情形都得手動指定：

```bash
pwsh -NoProfile -File ./setup-gemma.ps1 -Model gemma4:26b-a4b-it-qat -Context 32768
```

要調整就改 `gemma-setup/setup-gemma.ps1` 裡的 `$GpuProfiles` / `$CpuProfiles`。

### 上下文吃多少 VRAM（實測）

`gemma4:12b` 在 RTX 5060 Ti 16GB 上，用 `nvidia-smi` 量到的模型佔用量：

| num_ctx | 佔用 VRAM | 放置 |
|---------|----------|------|
| 4,096 | 8,181 MiB | 100% GPU |
| 16,384 | 8,685 MiB | 100% GPU |
| 32,768 | 8,973 MiB | 100% GPU |
| 65,536 | 9,550 MiB | 100% GPU |
| 131,072 | 10,291 MiB | 100% GPU |
| 196,608 | 11,376 MiB | 100% GPU |
| 262,144 | 12,467 MiB | 100% GPU |

從 4K 拉到 131K，VRAM 只多吃 2.1 GB —— Gemma 用滑動視窗注意力（每 5 層局部、1 層全域），KV cache 幾乎不隨上下文線性成長，跟一般 Transformer 的直覺很不一樣。所以本專案的選型表在上下文上給得比多數教學大方。

選 131072 而不是上限 262144，是為了留約 3.7 GB 給桌面環境波動。VRAM 一旦不足，Ollama 會把部分層丟回 CPU，速度直接掉一個數量級。

要在自己的機器上重量一次：`ollama stop <模型>`，用原生 API 帶 `options.num_ctx` 送一則訊息，再看 `nvidia-smi` 的差值。（`ollama ps` 的 SIZE 欄位不太可靠，會在 8.1～8.5 GB 之間跳。）

## 為什麼上下文要設兩次

這是本地模型跑 agent 最常見的坑，兩個地方缺一不可：

**Ollama 端 — `OLLAMA_CONTEXT_LENGTH`**

Ollama 0.30 之後預設值是「依 VRAM 動態決定」：未滿 23 GB 的機器一律只給 **4096**，23 GB 以上給 32768，47 GB 以上給 262144。所以一台 16 GB 顯卡的電腦如果沒設這個變數，實際跑起來就是 4K 上下文——OpenCode 那邊寫多大都沒用，工具呼叫會頻繁失敗、對話很快就斷。

> ⚠️ **設了環境變數也不保證生效。** Ollama 0.32 的**桌面 app** 把自己的 context length 設定（出廠預設 32768）存在 `db.sqlite`，啟動 server 時會拿它覆蓋環境變數，而且完全沒有提示 —— 重開機後又會再蓋一次。腳本會比對 server log 記的實際注入值並在不一致時報警。修法是把桌面 app 設定裡的 context length 也改成同一個值，或關掉桌面 app 改用 `ollama serve`。

Windows 設使用者環境變數即可。**macOS 麻煩一點**：要用 `launchctl setenv`，而且它活不過重開機 —— 所以腳本還會在 `~/Library/LaunchAgents/ai.ollama.env.plist` 寫一個登入時自動重設的 LaunchAgent，否則你某天重開機後上下文會悄悄掉回 4096 而毫無徵兆。要移除：

```bash
launchctl bootout gui/$(id -u)/ai.ollama.env && rm ~/Library/LaunchAgents/ai.ollama.env.plist
```

另外要注意 `OLLAMA_CONTEXT_LENGTH` 是**全域**的，Ollama 上每個模型都吃這個值；而 `opencode.json` 的 `limit.context` 是**逐一模型**的。日後若在同一台 Ollama 上再拉一個明顯更大的模型，全域值可能讓它配不下而掉層到 CPU。屆時的解法是全域設保守值、個別模型用 Modelfile 拉高：

```
FROM gemma4:12b
PARAMETER num_ctx 16384
```

（實測驗證過：這樣建出來的衍生模型走 OpenAI 相容端點載入時，`ollama ps` 的 CONTEXT 確實會蓋過全域設定。衍生模型共用權重 blob，不額外佔磁碟。）

**OpenCode 端 — `limit.context`**

```json
"models": {
  "gemma4:12b": {
    "name": "gemma4:12b (local)",
    "tool_call": true,
    "limit": { "context": 131072, "output": 16384 }
  }
}
```

注意欄位名是 `limit.context`。網路上不少舊教學寫的 `contextLength` **不在 OpenCode 的 schema 裡**，會被靜默忽略。腳本會自動把既有設定裡的 `contextLength` 清掉。

## 參數

| 參數 | 用途 |
|------|------|
| `-Plan` | 只偵測與建議，不改動任何東西 |
| `-Check` | 只檢查現況（含 `ollama ps` 的實際上下文，以及環境變數是否真的被 Ollama 吃到） |
| `-Model <tag>` | 指定模型，跳過自動選型 |
| `-Context <n>` | 指定上下文長度，跳過自動建議 |
| `-KvCache q8_0` | KV cache 量化，相同 VRAM 可塞下約兩倍上下文，品質損失很小 |
| `-ConfigPath <path>` | 改寫別的設定檔（預設 `~/.config/opencode/opencode.json`；同目錄的 `.jsonc` 也會被盤點並警告） |
| `-SkipInstall` | 已自行裝好 Ollama 時跳過安裝 |
| `-Yes` | 全程不詢問 |

範例：8 GB 顯卡想換更大的模型並犧牲一點上下文

```powershell
pwsh -NoProfile -File ./.opencode/skills/gemma-setup/setup-gemma.ps1 -Model gemma4:12b -Context 16384 -KvCache q8_0
```

## 疑難排解

| 症狀 | 處理 |
|------|------|
| 工具呼叫一直失敗、對話很快就斷 | 上下文太小。跑 `-Check` 看 `OLLAMA_CONTEXT_LENGTH` 與 `ollama ps` 的 CONTEXT 欄位 |
| `ollama ps` 的 PROCESSOR 顯示 CPU 或 CPU/GPU 混合 | 模型加上下文超出 VRAM。改小 `-Context`，或加 `-KvCache q8_0` |
| 重開機後上下文變回 4096（macOS） | LaunchAgent 沒建立或被移除。跑 `-Check` 會告訴你 |
| `-Check` 說「上下文對不上」 | Ollama 桌面 app 用自己的 GUI 設定蓋掉了環境變數。到 app 的 Settings 把 context length 改成同一個值，或改用 `ollama serve` |
| 改了環境變數卻沒效果 | Ollama 服務要重啟（腳本會做）。若重啟了還是沒效果，看上一列 |
| AMD 顯卡沒吃到 GPU | Ollama 的 ROCm 只支援部分 gfx 型號，不支援時會自動退回 CPU |
| 腳本一開就報語法錯誤 | 用到了 Windows PowerShell 5.1。必須用 `pwsh`（PowerShell 7） |
| Intel Mac 被擋下 | 沒有 Ollama 可用的 GPU 加速，不支援 |
| 想還原設定 | 腳本每次寫入前都會備份成 `opencode.json.bak-<時間戳>` |

## 環境需求

- Windows，或 Apple Silicon 的 macOS
- PowerShell 7 以上（Windows 用 `pwsh`；macOS 先 `brew install --cask powershell`）
- OpenCode
- Windows 需要 `winget`（沒有的話會改用官方安裝檔，並先詢問）；macOS 需要 Homebrew

## 開發

改過腳本後跑一次隔離測試——不連網、不安裝、不下載模型、不動環境變數、不碰真正的 `opencode.json`：

```powershell
pwsh -NoProfile -File ./tests/test-setup-gemma.ps1
```

89 項，涵蓋語法與編碼、Windows 與 Apple Silicon 兩條選型路徑、顯卡篩選、LaunchAgent 的 plist 是否為合法 XML、設定合併與備份、`.json`／`.jsonc` 並存的處理，以及 server log 的上下文解析與不一致偵測。

## 資料夾結構

```text
agent-gemma/
├── .opencode/skills/gemma-setup/   # OpenCode 專案技能（不裝到全域）
│   ├── SKILL.md                    # 觸發條件與 Agent 執行流程
│   └── setup-gemma.ps1             # 偵測、安裝、設定、驗證的主腳本
├── tests/
│   └── test-setup-gemma.ps1
├── agents.md              # 跨 Agent 專案藍圖
├── handoff.md             # 跨工作階段交接（不進 repo）
├── CLAUDE.md              # Claude Code 橋接
├── README.md
├── LICENSE
├── .gitattributes
└── .gitignore
```

技能刻意放在 `.opencode/skills/` 這個**專案層級**路徑，只在這個專案裡生效，不安裝到 `~/.config/opencode/skills/`。它只服務 OpenCode 接本機模型這一件事，沒有跨專案使用的理由，也不需要 `sync-skills` 同步到其他 Agent。

## 授權

MIT

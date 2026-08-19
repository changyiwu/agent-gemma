---
name: gemma-setup
description: 在本機把 Ollama ＋ Google Gemma 裝好並接進 OpenCode，支援 Windows 與 Apple Silicon macOS。當使用者說「設定 Gemma」「裝本地模型」「在 OpenCode 用 Gemma」「接本機大模型」「Ollama 設定」「新電腦要裝 Gemma」「本地模型上下文太小」「gemma 跑不動 / 選哪個版本」時，請一定要使用此技能。會依顯示卡 VRAM（Mac 則依統一記憶體）自動選版本、設定 Ollama 端上下文長度、並寫進 opencode.json。
---

# gemma-setup — 本機 Gemma 接進 OpenCode

## 用途

在一台新電腦上把「OpenCode 呼叫本機 Gemma」從零設定到能用：

1. 偵測顯示卡與 VRAM
2. 依 VRAM 選出跑得動的 Gemma 版本
3. 安裝 Ollama、下載模型
4. 設定 Ollama 端的上下文長度（這步最容易被漏掉）
5. 寫入 OpenCode 的 `opencode.json`
6. 實際送一則訊息驗證

主腳本：本技能資料夾的 `setup-gemma.ps1`。

這是**專案層級**技能（`.opencode/skills/`），只在 agent-gemma 專案裡生效，刻意不安裝到全域。不要用 `sync-skills` 把它同步到其他 Agent 的技能目錄。

## 支援平台

| 平台 | 加速 | 備註 |
|------|------|------|
| Windows + NVIDIA | CUDA | 已在 RTX 5060 Ti 16GB 實測 |
| Windows + AMD 獨顯 | ROCm | Ollama 只認部分 gfx 型號 |
| macOS + Apple Silicon | Metal | 已實作，**尚未實機驗證** |
| macOS + Intel | 無 | 不支援，腳本會擋掉 |

在 Apple Silicon 上第一次跑時，要留意這幾件事並回報給使用者：偵測到的晶片與統一記憶體是否正確、LaunchAgent 有沒有建立成功、`ollama ps` 的 CONTEXT 是不是等於設定值。

## 環境需求

- **必須用 PowerShell 7（`pwsh`）執行**。腳本是 UTF-8 無 BOM，Windows PowerShell 5.1 會用系統 ANSI 解讀而在 parse 階段就失敗，而且 `ConvertFrom-Json -AsHashtable` 在 5.1 不存在。macOS 上先 `brew install --cask powershell`。
- Windows 需要 `winget`（沒有的話會改用官方安裝檔，並先詢問）；macOS 需要 Homebrew。

## 執行流程

### 第一步：一定先跑 `-Plan`

不做任何改動，只印出偵測到的硬體與建議方案。把結果讀給使用者聽，確認後才繼續。

```powershell
pwsh -NoProfile -File "<本技能資料夾>\setup-gemma.ps1" -Plan
```

### 第二步：正式設定

```powershell
pwsh -NoProfile -File "<本技能資料夾>\setup-gemma.ps1"
```

每個會改動系統的步驟都會問一次（安裝 Ollama、下載模型、設定環境變數、macOS 建立 LaunchAgent、覆寫 `opencode.json`）。
**不要主動加 `-Yes`**，除非使用者明確說「都不用問」，或執行環境無法回應互動提示（例如非互動式終端），此時要先向使用者說明將自動同意哪些步驟。

### 想檢查現況

```powershell
pwsh -NoProfile -File "<本技能資料夾>\setup-gemma.ps1" -Check
```

會列出 ollama 版本、服務狀態、三個 `OLLAMA_*` 環境變數、OpenCode 裡每個模型的 `limit.context`，以及 `ollama ps` 的實際載入狀態。

## 參數

| 參數 | 用途 |
|------|------|
| `-Plan` | 只偵測與建議，不改動任何東西 |
| `-Check` | 只檢查現況 |
| `-Model <tag>` | 指定模型，跳過自動選型 |
| `-Context <n>` | 指定上下文長度，跳過自動建議 |
| `-KvCache q8_0` | KV cache 量化，相同 VRAM 可塞下約兩倍上下文 |
| `-ConfigPath <path>` | 改寫別的設定檔（預設 `~/.config/opencode/opencode.json`） |
| `-SkipInstall` | 已自行裝好 Ollama 時跳過安裝 |
| `-Yes` | 全程不詢問 |

## 選型表（VRAM → 模型）

| VRAM | 模型 | 下載大小 | 上下文 |
|------|------|---------|--------|
| 48 GB+ | `gemma4:31b-it-q8_0` | 34 GB | 131072 |
| 32 GB | `gemma4:31b-it-qat` | 19 GB | 65536 |
| 24 GB | `gemma4:26b-a4b-it-qat` | 16 GB | 32768 |
| 16 GB | `gemma4:12b` | 7.6 GB | 131072 |
| 10–12 GB | `gemma4:12b` | 7.6 GB | 32768 |
| 8 GB | `gemma4:e4b-it-qat` | 6.1 GB | 32768 |
| ≤ 6 GB | `gemma4:e2b-it-qat` | 4.3 GB | 16384 |

Apple Silicon 是統一記憶體，腳本先換算成「等效 VRAM」（36GB 以下取 70%、以上取 80%）再套用同一張表。例如 16GB Mac → 11.2GB → `gemma4:12b` @ 32768；64GB Mac → 51.2GB → `gemma4:31b-it-q8_0` @ 131072。

沒有可用 GPU 時，改依系統記憶體走 CPU 路徑（很慢，只建議拿來確認流程能通）。
表格寫在 `setup-gemma.ps1` 的 `$GpuProfiles` / `$CpuProfiles`，要調整就改那裡。

## 兩個一定要講清楚的重點

**1. 上下文要在兩個地方各設一次，缺一不可。**

- **Ollama 端**：Windows 是使用者環境變數 `OLLAMA_CONTEXT_LENGTH`；macOS 是 `launchctl setenv` 加上一個 LaunchAgent（`launchctl` 的設定活不過重開機）。Ollama 0.30 之後預設值是「依 VRAM 動態決定」——未滿 23 GB 的機器一律只給 **4096**。不設這個，OpenCode 那邊寫多大都沒用，agent 的工具呼叫會頻繁失敗。
- **OpenCode 端**：`opencode.json` 裡的 `limit.context`。

兩者作用範圍相反：`OLLAMA_CONTEXT_LENGTH` 是全域（Ollama 上每個模型都吃），`limit.context` 是逐一模型。要逐一模型控制實際上下文，只能用 Modelfile 的 `PARAMETER num_ctx`（`num_ctx` 無法從 OpenAI 相容端點傳入，已實測）。

**2. `contextLength` 不是合法欄位。**

OpenCode 的 schema 只認 `limit: { context, output }`。網路上不少舊教學寫 `contextLength`，那個會被靜默忽略。腳本會自動把既有設定裡的 `contextLength` 清掉。

## 設定完成後

上下文由 Ollama 伺服器決定，腳本已重啟它並套用設定，不需要重開終端機。在 OpenCode 裡：

- `/models` 選 **Ollama (local)** 底下的項目
- 或在設定裡指定 `"model": "ollama/gemma4:12b"`

## 常見狀況

| 症狀 | 處理 |
|------|------|
| 工具呼叫一直失敗、對話很快就斷 | 上下文太小。跑 `-Check` 看 `OLLAMA_CONTEXT_LENGTH` 與 `ollama ps` 的 CONTEXT 欄位 |
| `ollama ps` 的 PROCESSOR 顯示 CPU | 模型加上下文超出 VRAM。改小 `-Context`，或用 `-KvCache q8_0` |
| 改了環境變數卻沒效果 | Ollama 服務要重啟（腳本會做） |
| 重開機後上下文掉回 4096（macOS） | LaunchAgent 沒建立或被移除，跑 `-Check` 會指出 |
| AMD 顯卡沒吃到 GPU | Ollama 的 ROCm 只支援部分 gfx 型號，不支援時會自動退回 CPU |
| 回應速度可接受但品質不夠 | 往上一階換模型，或改用 `-it-q8_0` 版本 |

## 測試

改過腳本後跑一次隔離測試（不連網、不安裝、不碰真正的設定檔）：

```powershell
pwsh -NoProfile -File "<專案根目錄>\tests\test-setup-gemma.ps1"
```

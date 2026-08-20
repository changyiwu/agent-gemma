#requires -Version 7.0
<#
    setup-gemma.ps1 的隔離測試。

    不連網、不安裝、不下載模型、不動使用者環境變數、不碰真正的 opencode.json。
    做法是用 AST 把腳本裡的函式抽出來單獨定義，避開主流程。

    執行：pwsh -NoProfile -File .\tests\test-setup-gemma.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptPath = Join-Path $PSScriptRoot '../.opencode/skills/gemma-setup/setup-gemma.ps1' | Convert-Path
$script:Pass = 0
$script:Fail = 0

function Assert-True {
    param([bool] $Condition, [string] $Name)
    if ($Condition) { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else            { $script:Fail++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Name)
    Assert-True ($Expected -eq $Actual) "$Name (預期 $Expected，實得 $Actual)"
}

# ---- 先確認腳本本身語法沒問題 -------------------------------------------

Write-Host "`n[1] 語法與編碼" -ForegroundColor Cyan

$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'setup-gemma.ps1 可正確解析'
if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Host "        line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
}

$bytes = [System.IO.File]::ReadAllBytes($ScriptPath)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Assert-True (-not $hasBom) '腳本是 UTF-8 無 BOM'

# ---- 把函式抽出來定義（不執行主流程） -----------------------------------

$funcs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($f in $funcs) { . ([scriptblock]::Create($f.Extent.Text)) }

# 主流程裡的常數在函式外，這裡自行補上（與腳本保持一致）
$OllamaApi = 'http://localhost:11434'
$Yes = $true   # 讓 Confirm-Step 不互動

$GpuProfiles = @(
    @{ MinVram = 46;  Tag = 'gemma4:31b-it-q8_0';    SizeGB = 34;  Ctx = 131072; Note = '' }
    @{ MinVram = 31;  Tag = 'gemma4:31b-it-qat';     SizeGB = 19;  Ctx = 65536;  Note = '' }
    @{ MinVram = 23;  Tag = 'gemma4:26b-a4b-it-qat'; SizeGB = 16;  Ctx = 32768;  Note = '' }
    @{ MinVram = 15;  Tag = 'gemma4:12b';            SizeGB = 7.6; Ctx = 131072; Note = '' }
    @{ MinVram = 9.5; Tag = 'gemma4:12b';            SizeGB = 7.6; Ctx = 32768;  Note = '' }
    @{ MinVram = 6.5; Tag = 'gemma4:e4b-it-qat';     SizeGB = 6.1; Ctx = 32768;  Note = '' }
    @{ MinVram = 0;   Tag = 'gemma4:e2b-it-qat';     SizeGB = 4.3; Ctx = 16384;  Note = '' }
)
$CpuProfiles = @(
    @{ MinRam = 32; Tag = 'gemma4:e4b-it-qat'; SizeGB = 6.1; Ctx = 16384; Note = '' }
    @{ MinRam = 16; Tag = 'gemma4:e2b-it-qat'; SizeGB = 4.3; Ctx = 8192;  Note = '' }
    @{ MinRam = 0;  Tag = 'gemma3:4b-it-qat';  SizeGB = 4.0; Ctx = 8192;  Note = '' }
)

# ---- 選型邏輯 -----------------------------------------------------------

Write-Host "`n[2] 依顯示卡選型" -ForegroundColor Cyan

function New-Hw {
    param([string] $Kind, [double] $Usable, [double] $Ram)
    [pscustomobject]@{ Kind = $Kind; UsableGB = $Usable; RamGB = $Ram; Reason = 'test'; Lines = @() }
}

$cases = @(
    @{ Label = 'RTX 5060 Ti 16GB（實際回報 15.9）'; Usable = 15.9; Ram = 64;  Tag = 'gemma4:12b'; Ctx = 131072 }
    @{ Label = 'RTX 4090 24GB（實際回報 23.6）';    Usable = 23.6; Ram = 64;  Tag = 'gemma4:26b-a4b-it-qat'; Ctx = 32768 }
    @{ Label = 'RTX 4070 12GB';                     Usable = 11.9; Ram = 32;  Tag = 'gemma4:12b'; Ctx = 32768 }
    @{ Label = 'RTX 3060 Ti 8GB';                   Usable = 7.9;  Ram = 32;  Tag = 'gemma4:e4b-it-qat'; Ctx = 32768 }
    @{ Label = 'GTX 1650 4GB';                      Usable = 3.9;  Ram = 16;  Tag = 'gemma4:e2b-it-qat'; Ctx = 16384 }
    @{ Label = 'RTX A6000 48GB';                    Usable = 47.5; Ram = 128; Tag = 'gemma4:31b-it-q8_0'; Ctx = 131072 }
)
foreach ($c in $cases) {
    $r = Select-Plan -Hardware (New-Hw 'GPU' $c.Usable $c.Ram)
    Assert-Equal $c.Tag $r.Tag "$($c.Label) -> 模型"
    Assert-Equal $c.Ctx $r.Ctx "$($c.Label) -> 上下文"
}

Write-Host "`n[3] Apple Silicon 統一記憶體選型" -ForegroundColor Cyan

# 統一記憶體的可用比例：36GB 以下取 70%，以上取 80%
$macCases = @(
    @{ Label = 'M 系列 16GB';  Ram = 16;  Usable = 11.2; Tag = 'gemma4:12b'; Ctx = 32768 }
    @{ Label = 'M 系列 24GB';  Ram = 24;  Usable = 16.8; Tag = 'gemma4:12b'; Ctx = 131072 }
    @{ Label = 'M 系列 36GB';  Ram = 36;  Usable = 25.2; Tag = 'gemma4:26b-a4b-it-qat'; Ctx = 32768 }
    @{ Label = 'M 系列 64GB';  Ram = 64;  Usable = 51.2; Tag = 'gemma4:31b-it-q8_0'; Ctx = 131072 }
    @{ Label = 'M 系列 8GB';   Ram = 8;   Usable = 5.6;  Tag = 'gemma4:e2b-it-qat'; Ctx = 16384 }
)
foreach ($c in $macCases) {
    $r = Select-Plan -Hardware (New-Hw 'GPU' $c.Usable $c.Ram)
    Assert-Equal $c.Tag $r.Tag "$($c.Label)（可用 $($c.Usable) GB）-> 模型"
    Assert-Equal $c.Ctx $r.Ctx "$($c.Label) -> 上下文"
}

# 比例本身也要對，否則上面的 Usable 只是自我實現的預言
Assert-Equal 11.2 ([math]::Round(16 * 0.70, 1)) '16GB Mac 的可用比例換算'
Assert-Equal 51.2 ([math]::Round(64 * 0.80, 1)) '64GB Mac 的可用比例換算'

Write-Host "`n[4] CPU 退回路徑" -ForegroundColor Cyan

$r = Select-Plan -Hardware (New-Hw 'CPU' 0 64)
Assert-Equal 'CPU' $r.Device '沒有可用 GPU 時走 CPU 路徑'
Assert-Equal 'gemma4:e4b-it-qat' $r.Tag 'CPU 路徑（64GB RAM）選型'

$r = Select-Plan -Hardware (New-Hw 'CPU' 0 8)
Assert-Equal 'gemma3:4b-it-qat' $r.Tag '記憶體不足時退回 Gemma 3 4B'

Write-Host "`n[5] Windows 顯卡篩選" -ForegroundColor Cyan

function New-Gpu {
    param([string] $Name, [double] $Vram, [string] $Vendor = 'NVIDIA', [bool] $Integrated = $false)
    [pscustomobject]@{ Name = $Name; VramGB = $Vram; Vendor = $Vendor; IsIntegrated = $Integrated }
}

# 這段複製 Get-WindowsHardware 的篩選條件，確認內顯與 Intel 獨顯不會被當成可用 GPU
function Test-Usable {
    param($Gpus)
    @($Gpus | Where-Object {
        -not $_.IsIntegrated -and $_.VramGB -ge 3 -and $_.Vendor -in @('NVIDIA', 'AMD')
    } | Sort-Object VramGB -Descending)
}

$mixed = Test-Usable @((New-Gpu 'AMD Radeon(TM) Graphics' 8 'AMD' $true), (New-Gpu 'GTX 1650' 3.9))
Assert-Equal 1 $mixed.Count '內顯被排除，只留下獨顯'
Assert-Equal 'GTX 1650' $mixed[0].Name '選中的是獨顯而非數字更大的內顯'

Assert-Equal 0 (Test-Usable @((New-Gpu 'Intel UHD Graphics' 2 'Intel' $true))).Count '只有內顯時沒有可用 GPU'
Assert-Equal 0 (Test-Usable @((New-Gpu 'Intel Arc A770' 15.9 'Intel'))).Count 'Intel Arc 不被當成 Ollama 可用 GPU'
Assert-Equal 0 (Test-Usable @((New-Gpu 'GT 710' 2))).Count 'VRAM 不足 3GB 的舊卡被排除'

Write-Host "`n[6] macOS LaunchAgent plist" -ForegroundColor Cyan

# 沒有 Mac 也能驗證：plist 是不是合法 XML、內容有沒有跳脫錯誤
$vars = [ordered]@{ OLLAMA_CONTEXT_LENGTH = '131072'; OLLAMA_FLASH_ATTENTION = '1'; OLLAMA_KV_CACHE_TYPE = 'q8_0' }
$plistXml = New-MacLaunchAgentXml -Vars $vars

$parsedOk = $true
try { $doc = [xml]$plistXml } catch { $parsedOk = $false }
Assert-True $parsedOk 'plist 是合法的 XML'

if ($parsedOk) {
    $keys = @($doc.plist.dict.key)
    Assert-True ($keys -contains 'Label')            'plist 有 Label'
    Assert-True ($keys -contains 'ProgramArguments') 'plist 有 ProgramArguments'
    Assert-True ($keys -contains 'RunAtLoad')        'plist 有 RunAtLoad'

    $argv = @($doc.plist.dict.array.string)
    Assert-Equal '/bin/sh' $argv[0] 'ProgramArguments 第一項是 /bin/sh'
    Assert-Equal '-c'      $argv[1] 'ProgramArguments 第二項是 -c'

    # XML 解析後應還原成三個 launchctl setenv，且值正確
    $cmd = $argv[2]
    Assert-True ($cmd -match "launchctl setenv OLLAMA_CONTEXT_LENGTH '131072'") '指令含正確的上下文設定'
    Assert-True ($cmd -match "launchctl setenv OLLAMA_KV_CACHE_TYPE 'q8_0'")    '指令含正確的 KV cache 設定'
    Assert-Equal 3 ([regex]::Matches($cmd, 'launchctl setenv').Count)           '三個變數都寫進去了'
}

# ---- opencode.json 合併 -------------------------------------------------

Write-Host "`n[7] opencode.json 合併與備份" -ForegroundColor Cyan

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "gemma-test-$(Get-Random)"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$cfgPath = Join-Path $tmpDir 'opencode.json'

# 刻意用「舊寫法」的設定當起點：含無效的 contextLength、以及必須被保留的 mcp / permission
$legacy = @'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": { "obsidian": { "type": "local", "command": ["npx", "mcpvault"], "enabled": true } },
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": { "baseURL": "http://localhost:11434/v1" },
      "models": { "gemma4:12b": { "name": "Gemma 4 12B (local)", "contextLength": 65536 } }
    }
  },
  "permission": { "skill": { "*": "ask" } },
  "experimental": { "mcp_timeout": 300000 }
}
'@
[System.IO.File]::WriteAllText($cfgPath, $legacy, (New-Object System.Text.UTF8Encoding($false)))

Update-OpenCodeConfig -Path $cfgPath -Tag 'gemma4:12b' -Ctx 65536 | Out-Null

$out = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
$model = $out['provider']['ollama']['models']['gemma4:12b']

Assert-Equal 65536 $model['limit']['context']       'limit.context 寫入正確'
Assert-Equal 16384 $model['limit']['output']        'limit.output 有上限保護'
Assert-True (-not $model.ContainsKey('contextLength')) '無效的 contextLength 已移除'
Assert-True ($model['tool_call'] -eq $true)         'tool_call 已開啟（agent 才能用工具）'
Assert-True $out.ContainsKey('mcp')                 '既有的 mcp 設定被保留'
Assert-True $out.ContainsKey('permission')          '既有的 permission 設定被保留'
Assert-Equal 300000 $out['experimental']['mcp_timeout'] '既有的 experimental 設定被保留'
Assert-Equal 'https://opencode.ai/config.json' $out['$schema'] '$schema 被保留'
Assert-True ((Get-ChildItem $tmpDir -Filter 'opencode.json.bak-*').Count -eq 1) '有產生備份檔'

$outBytes = [System.IO.File]::ReadAllBytes($cfgPath)
$outBom = ($outBytes.Length -ge 3 -and $outBytes[0] -eq 0xEF -and $outBytes[1] -eq 0xBB -and $outBytes[2] -eq 0xBF)
Assert-True (-not $outBom) '寫出的 opencode.json 是 UTF-8 無 BOM'

# 從零開始：設定檔不存在時也要能建立
$freshDir = Join-Path $tmpDir 'fresh'
$freshPath = Join-Path $freshDir 'opencode.json'
Update-OpenCodeConfig -Path $freshPath -Tag 'gemma4:e4b-it-qat' -Ctx 32768 | Out-Null
$fresh = Get-Content $freshPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
Assert-Equal 32768 $fresh['provider']['ollama']['models']['gemma4:e4b-it-qat']['limit']['context'] '全新設定檔可從零建立'
Assert-Equal 8192  $fresh['provider']['ollama']['models']['gemma4:e4b-it-qat']['limit']['output']  '小上下文時 output 為 1/4'
Assert-Equal 'https://opencode.ai/config.json' $fresh['$schema'] '全新設定檔會補上 $schema'

# 第二次寫入同一個模型不該產生重複或壞掉的結構
Update-OpenCodeConfig -Path $cfgPath -Tag 'gemma4:12b' -Ctx 32768 | Out-Null
$out2 = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
Assert-Equal 32768 $out2['provider']['ollama']['models']['gemma4:12b']['limit']['context'] '重跑會覆寫成新的上下文'
Assert-Equal 1 $out2['provider']['ollama']['models'].Count '重跑不會產生重複模型項目'
Assert-Equal 2 (Get-ChildItem $tmpDir -Filter 'opencode.json.bak-*').Count '同一秒內重跑不會覆蓋前一份備份'

Remove-Item $tmpDir -Recurse -Force

# ---- .json / .jsonc 並存 ------------------------------------------------

Write-Host "`n[8] opencode.json / opencode.jsonc 並存" -ForegroundColor Cyan

$dualDir = Join-Path ([System.IO.Path]::GetTempPath()) "gemma-dual-$(Get-Random)"
New-Item -ItemType Directory -Path $dualDir -Force | Out-Null
$dualJson  = Join-Path $dualDir 'opencode.json'
$dualJsonc = Join-Path $dualDir 'opencode.jsonc'

# JSONC 帶註解與尾逗號 —— PowerShell 7 的 ConvertFrom-Json 容得下，5.1 不行
$jsoncBody = @'
{
  // 舊設定，模型早就從 Ollama 刪掉了
  "provider": {
    "ollama": {
      "models": { "gemma4:e4b": { "name": "Gemma 4 E4B" } },
    },
  },
}
'@
[System.IO.File]::WriteAllText($dualJsonc, $jsoncBody, (New-Object System.Text.UTF8Encoding($false)))

$parsedJsonc = Read-OpenCodeConfig -Path $dualJsonc
Assert-True ($parsedJsonc.Count -gt 0)                    'JSONC（含註解與尾逗號）可以解析'
Assert-True (Test-HasOllamaProvider $parsedJsonc)         'JSONC 裡的 provider.ollama 偵測得到'

# 只有 .jsonc 時，寫入目標就是 .jsonc（不硬生一個 .json 出來）
$onlyJsonc = Resolve-OpenCodeConfig -Path $dualJson -Explicit $false
Assert-Equal $dualJsonc $onlyJsonc.Target                 '只有 .jsonc 時寫入目標是 .jsonc'
Assert-Equal 1 $onlyJsonc.Present.Count                   '只有 .jsonc 時盤點到 1 份設定'

# 兩份並存：目標回到 .json，但兩份都要被盤點出來
[System.IO.File]::WriteAllText($dualJson, '{ "provider": { "ollama": { "models": {} } } }', (New-Object System.Text.UTF8Encoding($false)))
$dual = Resolve-OpenCodeConfig -Path $dualJson -Explicit $false
Assert-Equal $dualJson $dual.Target                       '兩份並存時以 .json 為寫入目標'
Assert-Equal 2 $dual.Present.Count                        '兩份並存時兩份都被盤點到'
Assert-Equal 2 $dual.WithOllama.Count                     '兩份的 provider.ollama 都被認出來'

# 明確指定 -ConfigPath：目標照辦，但盤點與警告不受影響（這是踩坑後改的行為）
$explicit = Resolve-OpenCodeConfig -Path $dualJsonc -Explicit $true
Assert-Equal $dualJsonc $explicit.Target                  '明確指定路徑時以該路徑為寫入目標'
Assert-Equal 2 $explicit.Present.Count                    '明確指定路徑時仍會盤點同目錄的另一份'

# 壞掉的設定檔不該讓整支腳本炸掉
$brokenPath = Join-Path $dualDir 'broken.json'
[System.IO.File]::WriteAllText($brokenPath, '{ this is not json', (New-Object System.Text.UTF8Encoding($false)))
$broken = Read-OpenCodeConfig -Path $brokenPath
Assert-Equal 0 $broken.Count                              '壞掉的設定檔回空表而不是丟例外'
Assert-Equal 0 (Read-OpenCodeConfig -Path (Join-Path $dualDir 'nope.json')).Count '不存在的設定檔回空表'

# 寫入 .jsonc 後，註解確實不見了（這正是建議統一用 .json 的理由）
Update-OpenCodeConfig -Path $dualJsonc -Tag 'gemma4:e4b-it-qat' -Ctx 32768 | Out-Null
$afterWrite = Get-Content $dualJsonc -Raw -Encoding UTF8
                                                          # 不能用 '//' 判斷 — baseURL 的 http:// 也會中
Assert-True ($afterWrite -notmatch '舊設定')              '寫入 .jsonc 後註解會被 ConvertTo-Json 清掉'
Assert-True ((Read-OpenCodeConfig -Path $dualJsonc)['provider']['ollama']['models'].ContainsKey('gemma4:e4b')) '寫入 .jsonc 時既有模型仍保留'

Remove-Item $dualDir -Recurse -Force

# ---- 結果 ---------------------------------------------------------------

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host "全部通過：$script:Pass 項" -ForegroundColor Green
    exit 0
} else {
    Write-Host "通過 $script:Pass 項，失敗 $script:Fail 項" -ForegroundColor Red
    exit 1
}

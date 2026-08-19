#requires -Version 7.0
<#
.SYNOPSIS
    在新電腦上一次設定好「OpenCode 呼叫本機 Gemma（Ollama）」。

.DESCRIPTION
    流程：偵測顯示卡 -> 選出適合的 Gemma 版本 -> 安裝 Ollama -> 拉模型
          -> 設定 Ollama 端上下文長度 -> 寫入 OpenCode 設定 -> 連線煙霧測試。

    所有會改動系統的步驟（安裝軟體、下載模型、設定使用者環境變數、
    覆寫 opencode.json）都會先詢問；加 -Yes 才會全程不問。

.EXAMPLE
    pwsh -NoProfile -File .\setup-gemma.ps1 -Plan
    只印出偵測結果與建議方案，不做任何改動。

.EXAMPLE
    pwsh -NoProfile -File .\setup-gemma.ps1
    互動式完整設定。

.EXAMPLE
    pwsh -NoProfile -File .\setup-gemma.ps1 -Model gemma4:e4b-it-qat -Context 32768 -Yes
    指定模型與上下文，全程不詢問。
#>
[CmdletBinding()]
param(
    # 指定 Ollama 模型 tag，跳過自動選型（例：gemma4:12b）
    [string] $Model,

    # 指定上下文長度（token），跳過自動建議
    [int] $Context,

    # KV cache 量化型別；q8_0 可讓相同 VRAM 塞下約兩倍上下文，品質損失很小
    [ValidateSet('f16', 'q8_0', 'q4_0')]
    [string] $KvCache,

    # OpenCode 全域設定檔位置
    [string] $ConfigPath = (Join-Path $HOME '.config/opencode/opencode.json'),

    # 只偵測並印出計畫，不做任何改動
    [switch] $Plan,

    # 只檢查目前狀態（含實際生效的上下文），不做任何改動
    [switch] $Check,

    # 跳過 Ollama 安裝步驟（已自行安裝時使用）
    [switch] $SkipInstall,

    # 全程不詢問，直接執行
    [switch] $Yes
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------- 常數

$OllamaApi    = 'http://localhost:11434'
$WingetId     = 'Ollama.Ollama'
$InstallerUrl = 'https://ollama.com/download/OllamaSetup.exe'

# 顯示卡 VRAM(GB) -> 建議的 Gemma 版本與上下文。由大到小比對，取第一個符合的。
# SizeGB 為 Ollama registry 上的下載大小；Ctx 為 f16 KV cache 下的保守值。
# MinVram 刻意壓在標稱值以下（16GB 卡實際回報約 15.9GB，24GB 卡約 23.6GB）。
$GpuProfiles = @(
    @{ MinVram = 46;  Tag = 'gemma4:31b-it-q8_0';    SizeGB = 34;  Ctx = 131072; Note = '31B 8-bit，48GB 專業卡，品質最接近原始權重' }
    @{ MinVram = 31;  Tag = 'gemma4:31b-it-qat';     SizeGB = 19;  Ctx = 65536;  Note = '31B QAT，32GB 顯卡' }
    @{ MinVram = 23;  Tag = 'gemma4:26b-a4b-it-qat'; SizeGB = 16;  Ctx = 32768;  Note = '26B MoE（僅啟用 4B），24GB 顯卡上比 31B 密集模型快很多' }
    # 16GB 這階的 131072 是實測值（RTX 5060 Ti 16GB / gemma4:12b）：
    # 4096 佔 8181 MiB、65536 佔 9550 MiB、131072 佔 10291 MiB、262144 佔 12467 MiB，全程 100% GPU。
    # Gemma 用滑動視窗注意力，KV cache 幾乎不隨上下文線性成長，所以可以放很大。
    # 取 131072 而非上限 262144，是為了留 3.7GB 給桌面環境波動；VRAM 一不足就會掉層到 CPU。
    @{ MinVram = 15;  Tag = 'gemma4:12b';            SizeGB = 7.6; Ctx = 131072; Note = '12B Q4_K_M，16GB 顯卡最穩的組合' }
    @{ MinVram = 9.5; Tag = 'gemma4:12b';            SizeGB = 7.6; Ctx = 32768;  Note = '12B Q4_K_M，上下文收斂以免溢位到 RAM' }
    @{ MinVram = 6.5; Tag = 'gemma4:e4b-it-qat';     SizeGB = 6.1; Ctx = 32768;  Note = 'E4B QAT，8GB 顯卡' }
    @{ MinVram = 0;   Tag = 'gemma4:e2b-it-qat';     SizeGB = 4.3; Ctx = 16384;  Note = 'E2B QAT，6GB 以下顯卡的保底選擇' }
)

# 沒有可用獨立顯卡時，改看系統記憶體（純 CPU 推論，速度慢很多）
$CpuProfiles = @(
    @{ MinRam = 32; Tag = 'gemma4:e4b-it-qat'; SizeGB = 6.1; Ctx = 16384; Note = 'CPU 推論，回應會很慢' }
    @{ MinRam = 16; Tag = 'gemma4:e2b-it-qat'; SizeGB = 4.3; Ctx = 8192;  Note = 'CPU 推論，回應會很慢' }
    @{ MinRam = 0;  Tag = 'gemma3:4b-it-qat';  SizeGB = 4.0; Ctx = 8192;  Note = '記憶體不足以跑 Gemma 4，退回 Gemma 3 4B' }
)

# 判定為內顯的名稱特徵（內顯不納入選型）
$IntegratedPattern = '(?i)(UHD|HD Graphics|Iris|Vega|Radeon\(TM\) Graphics|Integrated|Microsoft Basic|Remote Display)'

# ---------------------------------------------------------------- 輸出小工具

function Write-Step  { param([string]$m) Write-Host "`n>> $m" -ForegroundColor Cyan }
function Write-Ok    { param([string]$m) Write-Host "   [OK] $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "   [!]  $m" -ForegroundColor Yellow }
function Write-Info  { param([string]$m) Write-Host "   $m" -ForegroundColor Gray }

function Confirm-Step {
    param([string] $Message)
    if ($Yes) { Write-Info "$Message -> 已用 -Yes 自動同意"; return $true }
    $answer = Read-Host "   $Message [Y/n]"
    return ($answer -eq '' -or $answer -match '^[Yy]')
}

# ---------------------------------------------------------------- 硬體偵測

function Get-GpuInventory {
    <#  回傳每張顯示卡的 Name / VramGB / Vendor / IsIntegrated。
        NVIDIA 走 nvidia-smi（最準），其餘走登錄檔 qwMemorySize，
        因為 Win32_VideoController.AdapterRAM 是 32-bit，超過 4GB 會失真。 #>
    $result = [System.Collections.Generic.List[object]]::new()

    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        try {
            $lines = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
            foreach ($line in @($lines)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $parts = $line -split ',\s*'
                $result.Add([pscustomobject]@{
                    Name         = $parts[0].Trim()
                    VramGB       = [math]::Round(([double]$parts[1]) / 1024, 1)
                    Vendor       = 'NVIDIA'
                    IsIntegrated = $false
                })
            }
        } catch { }
    }

    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($sub in (Get-ChildItem $classKey -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty $sub.PSPath -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.PSObject.Properties['DriverDesc']) { continue }
        $name = [string]$p.DriverDesc
        # 已由 nvidia-smi 回報過的就不重複列
        if ($result | Where-Object { $_.Name -eq $name }) { continue }

        $bytes = 0
        if ($p.PSObject.Properties['HardwareInformation.qwMemorySize']) {
            $bytes = [double]$p.'HardwareInformation.qwMemorySize'
        }
        $vendor = switch -Regex ($name) {
            '(?i)nvidia|geforce|quadro|rtx|tesla' { 'NVIDIA'; break }
            '(?i)amd|radeon'                      { 'AMD';    break }
            '(?i)intel|arc'                       { 'Intel';  break }
            default                               { 'Other' }
        }
        $result.Add([pscustomobject]@{
            Name         = $name
            VramGB       = [math]::Round($bytes / 1GB, 1)
            Vendor       = $vendor
            IsIntegrated = ($name -match $IntegratedPattern)
        })
    }
    return $result
}

function Get-SystemRamGB {
    if ($IsMacOS) { return [math]::Round(([double](& sysctl -n hw.memsize)) / 1GB, 1) }
    [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
}

function Get-WindowsHardware {
    $gpus  = Get-GpuInventory
    $ramGB = Get-SystemRamGB

    $lines = @()
    if ($gpus.Count -eq 0) { $lines += '偵測不到任何顯示卡' }
    foreach ($g in $gpus) {
        $kind = if ($g.IsIntegrated) { '內顯' } else { '獨顯' }
        $lines += ('{0,-40} {1,6} GB  {2,-7} {3}' -f $g.Name, $g.VramGB, $g.Vendor, $kind)
    }
    $lines += "系統記憶體：$ramGB GB"

    # Ollama 在 Windows 上只有 NVIDIA(CUDA) 與部分 AMD 獨顯(ROCm) 能真正吃到 GPU
    $usable = @($gpus | Where-Object {
        -not $_.IsIntegrated -and $_.VramGB -ge 3 -and $_.Vendor -in @('NVIDIA', 'AMD')
    } | Sort-Object VramGB -Descending)

    if ($usable.Count -gt 0) {
        $gpu = $usable[0]
        $reason = "$($gpu.Name)（$($gpu.VramGB) GB VRAM）"
        if ($gpu.Vendor -eq 'AMD') {
            $reason += ' — AMD 走 ROCm，若 Ollama 回報不支援此 gfx 型號會自動退回 CPU'
        }
        return [pscustomobject]@{ Kind = 'GPU'; UsableGB = $gpu.VramGB; RamGB = $ramGB; Reason = $reason; Lines = $lines }
    }
    return [pscustomobject]@{
        Kind = 'CPU'; UsableGB = 0; RamGB = $ramGB
        Reason = "找不到 Ollama 可用的獨立顯卡，改用 CPU（系統記憶體 $ramGB GB）"
        Lines = $lines
    }
}

function Get-MacHardware {
    <#  只支援 Apple Silicon。統一記憶體是 CPU/GPU 共用，Metal 能取用的上限
        由 iogpu.wired_limit_mb 決定，未調整時約為總記憶體的 65~75%。
        這裡取保守比例，寧可低估也不要載入到一半才發現爆掉。 #>
    $arch = (& uname -m).Trim()
    if ($arch -ne 'arm64') {
        throw "偵測到 $arch 架構的 Mac。本腳本只支援 Apple Silicon（M 系列）；Intel Mac 沒有 Ollama 可用的 GPU 加速，跑起來不堪用。"
    }

    $chip  = (& sysctl -n machdep.cpu.brand_string).Trim()
    $ramGB = Get-SystemRamGB
    $ratio = if ($ramGB -gt 36) { 0.80 } else { 0.70 }
    $usableGB = [math]::Round($ramGB * $ratio, 1)

    $lines = @(
        ('{0,-40} {1,6} GB  統一記憶體' -f $chip, $ramGB)
        ("GPU 可取用約 {0} GB（總記憶體的 {1}%）" -f $usableGB, [int]($ratio * 100))
    )
    return [pscustomobject]@{
        Kind = 'GPU'; UsableGB = $usableGB; RamGB = $ramGB
        Reason = "$chip（統一記憶體 $ramGB GB，GPU 可取用約 $usableGB GB）"
        Lines = $lines
    }
}

function Get-HardwareReport {
    if ($IsWindows) { return Get-WindowsHardware }
    if ($IsMacOS)   { return Get-MacHardware }
    throw '不支援的平台：本腳本只支援 Windows 與 Apple Silicon macOS。'
}

function Select-Plan {
    <# 依硬體報告挑出模型與上下文；回傳含 Tag / Ctx / Reason 的物件。 #>
    param($Hardware)

    if ($Hardware.Kind -eq 'GPU') {
        $picked = $GpuProfiles | Where-Object { $Hardware.UsableGB -ge $_.MinVram } | Select-Object -First 1
        return [pscustomobject]@{
            Tag = $picked.Tag; Ctx = $picked.Ctx; SizeGB = $picked.SizeGB
            Note = $picked.Note; Reason = $Hardware.Reason; Device = 'GPU'
        }
    }

    $picked = $CpuProfiles | Where-Object { $Hardware.RamGB -ge $_.MinRam } | Select-Object -First 1
    return [pscustomobject]@{
        Tag = $picked.Tag; Ctx = $picked.Ctx; SizeGB = $picked.SizeGB
        Note = $picked.Note; Reason = $Hardware.Reason; Device = 'CPU'
    }
}

# ---------------------------------------------------------------- Ollama

function Test-OllamaUp {
    try {
        $null = Invoke-RestMethod -Uri "$OllamaApi/api/version" -TimeoutSec 3
        return $true
    } catch { return $false }
}

function Wait-OllamaUp {
    param([int] $TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-OllamaUp) { return $true }
        Start-Sleep -Milliseconds 800
    }
    return $false
}

function Install-Ollama {
    if (Get-Command ollama -ErrorAction SilentlyContinue) {
        Write-Ok "Ollama 已安裝（$((& ollama --version) -join ' ')）"
        return
    }
    if ($SkipInstall) { throw '找不到 ollama，且指定了 -SkipInstall。' }
    if (-not (Confirm-Step '尚未安裝 Ollama，要現在安裝嗎？')) { throw '使用者取消安裝。' }

    if ($IsMacOS) {
        if (-not (Get-Command brew -ErrorAction SilentlyContinue)) {
            throw '找不到 Homebrew。請先安裝 Homebrew，或自行到 https://ollama.com/download 下載 macOS 版後再跑一次。'
        }
        Write-Info '透過 Homebrew 安裝 ollama cask ...'
        & brew install --cask ollama
        if ($LASTEXITCODE -ne 0) { throw "brew install --cask ollama 失敗（exit $LASTEXITCODE）。" }
        if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
            throw '安裝完成但仍找不到 ollama，請重開終端機後再跑一次。'
        }
        Write-Ok 'Ollama 安裝完成'
        return
    }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Info "透過 winget 安裝 $WingetId ..."
        & winget install --id $WingetId --exact --source winget --accept-package-agreements --accept-source-agreements
    }
    else {
        Write-Warn2 "沒有 winget，改用官方安裝檔：$InstallerUrl"
        if (-not (Confirm-Step '要下載並執行 OllamaSetup.exe 嗎？')) { throw '使用者取消下載。' }
        $tmp = Join-Path $env:TEMP 'OllamaSetup.exe'
        Invoke-WebRequest -Uri $InstallerUrl -OutFile $tmp
        Start-Process -FilePath $tmp -Wait
    }

    # 安裝後 PATH 尚未在本 session 生效，補上預設安裝路徑
    $ollamaDir = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
    if (Test-Path $ollamaDir) { $env:Path = "$ollamaDir;$env:Path" }
    if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
        throw '安裝完成但仍找不到 ollama，請重開終端機後再跑一次。'
    }
    Write-Ok 'Ollama 安裝完成'
}

function Restart-OllamaServer {
    <# 環境變數只有在 server 重啟後才會生效。 #>
    Write-Info '重新啟動 Ollama 服務讓設定生效 ...'

    if ($IsMacOS) {
        # 先禮貌地請 GUI app 結束，再確保背景 serve 也收掉
        & osascript -e 'quit app "Ollama"' 2>$null
        & pkill -x ollama 2>$null
        Start-Sleep -Seconds 2
        if (Test-Path '/Applications/Ollama.app') { & open -a Ollama }
        else { Start-Process -FilePath 'ollama' -ArgumentList 'serve' }
    }
    else {
        Get-Process -Name 'ollama', 'ollama app' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        $appExe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'
        if (Test-Path $appExe) { Start-Process -FilePath $appExe }
        else { Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden }
    }

    if (Wait-OllamaUp -TimeoutSec 60) { Write-Ok 'Ollama 服務已就緒' }
    else { Write-Warn2 'Ollama 服務在 60 秒內沒回應，請手動確認。' }
}

function Install-GemmaModel {
    param([string] $Tag, [double] $SizeGB)

    $installed = @()
    try {
        $installed = @((& ollama list) | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] })
    } catch { }
    if ($installed -contains $Tag) { Write-Ok "模型 $Tag 已存在"; return }

    if (-not (Confirm-Step "要下載模型 $Tag（約 $SizeGB GB）嗎？")) { throw '使用者取消下載模型。' }
    & ollama pull $Tag
    if ($LASTEXITCODE -ne 0) { throw "ollama pull $Tag 失敗（exit $LASTEXITCODE）。" }
    Write-Ok "模型 $Tag 下載完成"
}

function Get-PersistentEnv {
    <# 讀取「跨行程可見」的環境變數：Windows 是使用者環境變數，macOS 是 launchctl。 #>
    param([string] $Name)
    if ($IsMacOS) { return "$(& launchctl getenv $Name 2>$null)".Trim() }
    return [Environment]::GetEnvironmentVariable($Name, 'User')
}

function Set-PersistentEnv {
    param([string] $Name, [string] $Value)
    if ($IsMacOS) {
        # 立即生效，Ollama 的 GUI app 重啟後就讀得到；但活不過重開機，
        # 所以後面還會寫一個 LaunchAgent 補上持久性。
        & launchctl setenv $Name $Value
    } else {
        [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    }
    Set-Item -Path "Env:$Name" -Value $Value
}

function New-MacLaunchAgentXml {
    <# 產生 LaunchAgent 的 plist 內容。抽成獨立函式是為了能在沒有 Mac 的機器上測試。 #>
    param([System.Collections.Specialized.OrderedDictionary] $Vars, [string] $Label = 'ai.ollama.env')

    # 值只會是數字或 f16/q8_0/q4_0 這類字面量，但仍做 XML 跳脫以免將來擴充時出錯
    $esc = { param($s) [System.Security.SecurityElement]::Escape("$s") }
    $cmd = (@($Vars.Keys | ForEach-Object { "launchctl setenv $_ '$($Vars[$_])'" }) -join '; ')

    return @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$(& $esc $Label)</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>$(& $esc $cmd)</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
"@
}

function Write-MacLaunchAgent {
    <#  launchctl setenv 不會活過重開機。寫一個登入時執行的 LaunchAgent 重設這些變數，
        否則使用者重開機後上下文會悄悄掉回 Ollama 的動態預設值。 #>
    param([System.Collections.Specialized.OrderedDictionary] $Vars)

    $label    = 'ai.ollama.env'
    $agentDir = Join-Path $HOME 'Library/LaunchAgents'
    $plist    = Join-Path $agentDir "$label.plist"

    if (-not (Confirm-Step "要建立 LaunchAgent（$plist）讓設定活過重開機嗎？")) {
        Write-Warn2 '略過 LaunchAgent — 這些變數會在下次重開機後失效'
        return
    }

    if (-not (Test-Path $agentDir)) { New-Item -ItemType Directory -Path $agentDir -Force | Out-Null }

    $xml = New-MacLaunchAgentXml -Vars $Vars -Label $label
    [System.IO.File]::WriteAllText($plist, $xml, (New-Object System.Text.UTF8Encoding($false)))

    $uid = "$(& id -u)".Trim()
    & launchctl bootout "gui/$uid/$label" 2>$null      # 舊的先卸載，忽略「本來就沒有」的錯誤
    & launchctl bootstrap "gui/$uid" $plist 2>$null
    Write-Ok "LaunchAgent 已建立：$plist"
    Write-Info "要移除：launchctl bootout gui/$uid/$label && rm '$plist'"
}

function Set-OllamaContext {
    param([int] $Ctx, [string] $KvCacheType)

    $wanted = [ordered]@{ OLLAMA_CONTEXT_LENGTH = "$Ctx" }
    if ($KvCacheType) {
        # KV cache 量化需要 flash attention 才會生效
        $wanted['OLLAMA_FLASH_ATTENTION'] = '1'
        $wanted['OLLAMA_KV_CACHE_TYPE']   = $KvCacheType
    }

    $target  = if ($IsMacOS) { 'launchctl 環境變數' } else { '使用者環境變數' }
    $changed = $false
    foreach ($name in $wanted.Keys) {
        $current = Get-PersistentEnv -Name $name
        if ($current -eq $wanted[$name]) { Write-Ok "$name 已是 $($wanted[$name])"; continue }
        $was = if ($current) { $current } else { '未設定' }
        if (-not (Confirm-Step "要把${target} $name 設為 $($wanted[$name]) 嗎？（原值：$was）")) {
            Write-Warn2 "略過 $name"
            continue
        }
        Set-PersistentEnv -Name $name -Value $wanted[$name]
        Write-Ok "$name = $($wanted[$name])"
        $changed = $true
    }

    if ($changed -and $IsMacOS) { Write-MacLaunchAgent -Vars $wanted }
    return $changed
}

# ---------------------------------------------------------------- OpenCode 設定

function Update-OpenCodeConfig {
    param([string] $Path, [string] $Tag, [int] $Ctx)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $config = @{}
    if (Test-Path $Path) {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8
        if ($raw.Trim()) { $config = $raw | ConvertFrom-Json -AsHashtable }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = "$Path.bak-$stamp"
        $n = 1
        while (Test-Path $backup) { $backup = "$Path.bak-$stamp-$n"; $n++ }  # 同一秒重跑不覆蓋舊備份
        Copy-Item -Path $Path -Destination $backup
        Write-Info "已備份原設定到 $(Split-Path -Leaf $backup)"
    }

    if (-not $config.ContainsKey('$schema'))   { $config['$schema'] = 'https://opencode.ai/config.json' }
    if (-not $config.ContainsKey('provider'))  { $config['provider'] = @{} }
    if (-not $config['provider'].ContainsKey('ollama')) { $config['provider']['ollama'] = @{} }

    $ollama = $config['provider']['ollama']
    $ollama['npm']     = '@ai-sdk/openai-compatible'
    $ollama['name']    = 'Ollama (local)'
    $ollama['options'] = @{ baseURL = "$OllamaApi/v1" }
    if (-not $ollama.ContainsKey('models')) { $ollama['models'] = @{} }

    $friendly = "$Tag (local)"
    $ollama['models'][$Tag] = @{
        name       = $friendly
        tool_call  = $true   # 讓 OpenCode 走原生 tool calling，agent 才能用工具
        reasoning  = $true   # Gemma 4 有 thinking 能力
        attachment = $true   # Gemma 4 支援圖片輸入
        limit      = @{ context = $Ctx; output = [math]::Min(16384, [int]($Ctx / 4)) }
    }

    # 清掉舊寫法：contextLength 不在 OpenCode schema 裡，寫了也不會生效
    foreach ($m in @($ollama['models'].Keys)) {
        $entry = $ollama['models'][$m]
        if ($entry -is [hashtable] -and $entry.ContainsKey('contextLength')) {
            $entry.Remove('contextLength')
            Write-Info "已移除 $m 的無效欄位 contextLength"
        }
    }

    $json = $config | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok "已寫入 $Path"
    Write-Info "在 OpenCode 內用 /models 選 [Ollama (local)] 的 $friendly，或設 model 為 ollama/$Tag"
}

# ---------------------------------------------------------------- 驗證

function Test-Setup {
    param([string] $Tag)

    Write-Info '送出一則測試訊息 ...'
    # Gemma 4 預設開著 thinking，會先吐一段 reasoning 才給 content。
    # max_tokens 給太小（例如 64）會在 reasoning 階段就用完，content 變成空字串、
    # finish_reason 是 length —— 看起來像成功其實沒答完，所以這裡給寬一點。
    $body = @{
        model      = $Tag
        messages   = @(@{ role = 'user'; content = '用一句繁體中文回答：你是誰？' })
        max_tokens = 512
    } | ConvertTo-Json -Depth 5

    try {
        $resp = Invoke-RestMethod -Uri "$OllamaApi/v1/chat/completions" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 300
    } catch {
        Write-Warn2 "測試請求失敗：$($_.Exception.Message)"
        return
    }

    $choice  = $resp.choices[0]
    $content = "$($choice.message.content)".Trim()
    $think   = "$($choice.message.reasoning)".Trim()

    if ($content) {
        Write-Ok "模型回應：$content"
        if ($think) { Write-Info "（另有 $($think.Length) 字的 thinking 內容，已略過）" }
    }
    elseif ($choice.finish_reason -eq 'length') {
        Write-Warn2 "回應被 max_tokens 截斷，content 是空的（thinking 用掉 $($resp.usage.completion_tokens) tokens）。模型會動，但這則測試不算通過。"
    }
    else {
        Write-Warn2 "模型沒有回傳 content（finish_reason: $($choice.finish_reason)）。"
    }

    # ollama ps 的 CONTEXT 欄位是「這次真的載入」的上下文，最有說服力的驗證
    Write-Info '目前載入狀態（CONTEXT 欄位即實際生效的上下文）：'
    & ollama ps | ForEach-Object { Write-Host "     $_" -ForegroundColor Gray }
}

function Show-Status {
    Write-Step '目前狀態'
    if (Get-Command ollama -ErrorAction SilentlyContinue) {
        Write-Ok "ollama：$((& ollama --version) -join ' ')"
    } else { Write-Warn2 'ollama：未安裝' }

    if (Test-OllamaUp) { Write-Ok "服務：$OllamaApi 可連線" } else { Write-Warn2 '服務：未啟動' }

    $envHints = [ordered]@{
        OLLAMA_CONTEXT_LENGTH  = '未設定 — Ollama 會依 VRAM 自行決定，未滿 23GB 只給 4096，跑 agent 一定不夠'
        OLLAMA_FLASH_ATTENTION = '未設定（選用；搭配 KV cache 量化時才需要）'
        OLLAMA_KV_CACHE_TYPE   = '未設定（選用；設 q8_0 可用相同 VRAM 塞下約兩倍上下文）'
    }
    foreach ($n in $envHints.Keys) {
        $v = Get-PersistentEnv -Name $n
        if ($v) { Write-Ok "$n = $v" } else { Write-Warn2 "$n $($envHints[$n])" }
    }

    if ($IsMacOS) {
        $plist = Join-Path $HOME 'Library/LaunchAgents/ai.ollama.env.plist'
        if (Test-Path $plist) { Write-Ok 'LaunchAgent 存在，設定可活過重開機' }
        else { Write-Warn2 '沒有 LaunchAgent — launchctl 的設定會在重開機後失效' }
    }

    if (Test-Path $ConfigPath) {
        $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ($cfg.ContainsKey('provider') -and $cfg['provider'].ContainsKey('ollama')) {
            foreach ($m in $cfg['provider']['ollama']['models'].Keys) {
                $entry = $cfg['provider']['ollama']['models'][$m]
                if ($entry -is [hashtable] -and $entry.ContainsKey('limit') -and $entry['limit']['context']) {
                    Write-Ok "OpenCode 模型 $m -> limit.context = $($entry['limit']['context'])"
                } else {
                    Write-Warn2 "OpenCode 模型 $m 沒有有效的 limit.context（contextLength 不是合法欄位，不會生效）"
                }
            }
        } else { Write-Warn2 'OpenCode 設定裡沒有 ollama provider' }
    } else { Write-Warn2 "找不到 $ConfigPath" }

    if (Test-OllamaUp) {
        Write-Info '已載入的模型：'
        & ollama ps | ForEach-Object { Write-Host "     $_" -ForegroundColor Gray }
    }
}

# ---------------------------------------------------------------- 主流程

if (-not ($IsWindows -or $IsMacOS)) { throw '本腳本只支援 Windows 與 Apple Silicon macOS。' }

Write-Host ''
Write-Host '=== OpenCode x Gemma (Ollama) 設定精靈 ===' -ForegroundColor Magenta

if ($Check) { Show-Status; return }

Write-Step '偵測硬體'
$hw = Get-HardwareReport
foreach ($line in $hw.Lines) { Write-Info $line }

Write-Step '選擇方案'
$auto = Select-Plan -Hardware $hw
$tag  = if ($Model)   { $Model }   else { $auto.Tag }
$ctx  = if ($Context) { $Context } else { $auto.Ctx }

Write-Info "依據　：$($auto.Reason)"
if ($Model) { Write-Info "模型　：$tag（由 -Model 指定）" }
else        { Write-Info "模型　：$tag　約 $($auto.SizeGB) GB — $($auto.Note)" }
if ($Context) { Write-Info "上下文：$ctx tokens（由 -Context 指定）" }
else          { Write-Info "上下文：$ctx tokens" }
if ($KvCache) { Write-Info "KV cache：$KvCache（可用相同 VRAM 塞下更長上下文）" }
if ($auto.Device -eq 'CPU') { Write-Warn2 '純 CPU 推論會非常慢，只建議拿來確認流程能通。' }

if ($Plan) {
    Write-Host "`n（-Plan 模式，未做任何改動）" -ForegroundColor Magenta
    return
}

Write-Step '安裝 Ollama'
Install-Ollama
if (-not (Test-OllamaUp)) { Restart-OllamaServer }

Write-Step '設定上下文長度'
$envChanged = Set-OllamaContext -Ctx $ctx -KvCacheType $KvCache

Write-Step '下載模型'
Install-GemmaModel -Tag $tag -SizeGB $auto.SizeGB

if ($envChanged) {
    Write-Step '套用環境變數'
    Restart-OllamaServer
}

Write-Step '寫入 OpenCode 設定'
if (Confirm-Step "要更新 $ConfigPath 嗎？（會先自動備份）") {
    Update-OpenCodeConfig -Path $ConfigPath -Tag $tag -Ctx $ctx
} else {
    Write-Warn2 '略過 OpenCode 設定'
}

Write-Step '驗證'
Test-Setup -Tag $tag

Write-Host "`n完成。" -ForegroundColor Magenta
Write-Info '上下文由 Ollama 伺服器決定，腳本已重啟它並套用設定，上面的 CONTEXT 欄位就是實際生效值。'
Write-Info '若日後自行從舊的終端機執行 ollama serve，記得那個 shell 可能還沒有新的環境變數 — 開新終端機即可。'

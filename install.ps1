# Claude 續跑模式 — 安裝程式
#   本機安裝：解壓後雙擊 install.bat（或 powershell -ExecutionPolicy Bypass -File install.ps1）
#   一行安裝：irm https://raw.githubusercontent.com/chuanchihsu1219/keep-awake/main/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRaw = 'https://raw.githubusercontent.com/chuanchihsu1219/keep-awake/main'
$files   = 'KeepAwakeTray.ps1', 'keep-awake.ps1', 'start-hidden.vbs', 'coffee.png'
$dest    = Join-Path $env:LOCALAPPDATA 'ClaudeKeepAwake'

Write-Host ''
Write-Host 'Claude 續跑模式 — 安裝中…' -ForegroundColor Cyan
New-Item -ItemType Directory -Path $dest -Force | Out-Null

# 來源：若在解壓後的資料夾執行就用本機檔；若是 irm|iex 一行安裝則從 GitHub 下載
$srcDir = $PSScriptRoot
$useLocal = $srcDir -and (Test-Path (Join-Path $srcDir 'KeepAwakeTray.ps1'))
foreach ($f in $files) {
    $target = Join-Path $dest $f
    if ($useLocal) {
        Copy-Item (Join-Path $srcDir $f) $target -Force
    }
    else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "$repoRaw/$f" -OutFile $target -UseBasicParsing
    }
    Write-Host "  ✓ $f"
}

# 停掉舊的（若正在跑），避免重複
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'KeepAwakeTray\.ps1' -and $_.CommandLine -notmatch '-Command' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 開機自動啟動捷徑
$startup = [Environment]::GetFolderPath('Startup')
$vbs = Join-Path $dest 'start-hidden.vbs'
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $startup 'ClaudeKeepAwake.lnk'))
$lnk.TargetPath = "$env:SystemRoot\System32\wscript.exe"
$lnk.Arguments = '"' + $vbs + '"'
$lnk.WorkingDirectory = $dest
$lnk.Description = 'Claude 續跑模式（系統匣開關）'
$lnk.Save()

# 立即啟動
Start-Process wscript.exe -ArgumentList ('"' + $vbs + '"')

Write-Host ''
Write-Host '✅ 安裝完成！右下角系統匣會出現咖啡杯圖示。' -ForegroundColor Green
Write-Host "   安裝位置：$dest"
Write-Host '   用法：左鍵切換、右鍵選單；開機會自動啟動。'
Write-Host '   解除安裝：雙擊 uninstall.bat（或跑 uninstall.ps1）。'
Write-Host ''

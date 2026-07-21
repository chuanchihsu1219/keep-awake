# Claude 續跑模式 — 解除安裝：停程式、還原電源設定、移除捷徑與檔案
$ErrorActionPreference = 'SilentlyContinue'
$dest = Join-Path $env:LOCALAPPDATA 'ClaudeKeepAwake'

Write-Host ''
Write-Host 'Claude 續跑模式 — 解除安裝中…' -ForegroundColor Cyan

# 1) 停掉系統匣程式
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'KeepAwakeTray\.ps1' -and $_.CommandLine -notmatch '-Command' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 500

# 2) 還原電源設定（以防停在續跑狀態）
$SUB = 'SUB_BUTTONS'; $LID = '5ca83367-6e45-459f-a27b-476b1d01c936'
powercfg /setacvalueindex SCHEME_CURRENT $SUB $LID 1 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT $SUB $LID 1 | Out-Null
powercfg /change standby-timeout-dc 5 | Out-Null
powercfg /setactive SCHEME_CURRENT | Out-Null

# 3) 移除開機捷徑
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudeKeepAwake.lnk') -Force

# 4) 移除安裝資料夾
Remove-Item $dest -Recurse -Force

Write-Host '✅ 已解除安裝，並把電源設定還原成正常。' -ForegroundColor Green
Write-Host ''

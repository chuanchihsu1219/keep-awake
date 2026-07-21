param([switch]$On, [switch]$Off)

# 讓筆電闔上時 Claude 繼續跑的快速開關
# On  : 闔蓋不睡眠 + 電池閒置不睡眠
# Off : 還原成正常（闔蓋睡眠 / 電池閒置 5 分鐘睡眠）

$SUB = 'SUB_BUTTONS'                                  # 電源按鈕及筆電螢幕
$LID = '5ca83367-6e45-459f-a27b-476b1d01c936'        # 闔蓋動作

function Set-Lid([int]$v) {
    powercfg /setacvalueindex SCHEME_CURRENT $SUB $LID $v | Out-Null   # 插電
    powercfg /setdcvalueindex SCHEME_CURRENT $SUB $LID $v | Out-Null   # 電池
}

# Windows 11 原生 toast（沿用 claude-notify 的寫法：專屬 AppID + LoadXml）
function Show-Toast([string]$title, [string]$l1, [string]$l2) {
    $appId = 'ClaudeCode.KeepAwake'
    $regBase = "HKCU:\SOFTWARE\Classes\AppUserModelId\$appId"
    if (-not (Test-Path $regBase)) { New-Item -Path $regBase -Force | Out-Null }
    New-ItemProperty -Path $regBase -Name 'DisplayName' -Value 'Claude 續跑模式' -PropertyType String -Force | Out-Null
    $esc = { param($s) $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $xml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$(& $esc $title)</text>
      <text>$(& $esc $l1)</text>
      <text>$(& $esc $l2)</text>
    </binding>
  </visual>
</toast>
"@
        # 5.1 無法 New-Object 這個 WinRT 型別，改用 GetTemplateContent 取現成 XmlDocument 再 LoadXml
        $doc = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $doc.LoadXml($xml)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
        # 相同 Tag/Group → 開/關的通知就地取代，不會愈疊愈多
        $toast.Group = 'ClaudeKeepAwake'
        $toast.Tag = 'state'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    }
    catch {
        (New-Object -ComObject WScript.Shell).Popup("$l1`n$l2", 6, $title, 64) | Out-Null
    }
}

if ($On) {
    Set-Lid 0                                  # 闔蓋 = 不做任何動作
    powercfg /change standby-timeout-dc 0      # 電池閒置 = 永不睡眠（插電本來就已是永不）
    powercfg /setactive SCHEME_CURRENT | Out-Null
    Write-Host 'Keep-awake: ON'
    Show-Toast 'Claude 續跑模式：已開啟 ✅' '闔上筆電，Claude 會繼續跑' '電池下也不會睡、會耗電發熱；用完請按「關」'
}
elseif ($Off) {
    Set-Lid 1                                  # 闔蓋 = 睡眠（Windows 預設）
    powercfg /change standby-timeout-dc 5      # 電池閒置 5 分鐘睡眠（還原）
    powercfg /setactive SCHEME_CURRENT | Out-Null
    Write-Host 'Keep-awake: OFF'
    Show-Toast 'Claude 續跑模式：已關閉' '電源設定已還原正常' '闔蓋＝睡眠、電池閒置 5 分鐘睡眠'
}
else {
    Write-Host '用法: keep-awake.ps1 -On | -Off'
    exit 1
}

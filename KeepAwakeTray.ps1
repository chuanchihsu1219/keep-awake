# KeepAwakeTray.ps1 — Claude 續跑模式（系統匣開關）
# 左鍵：切換（開＝預設 30 分鐘）；右鍵：選單（30 分 / 1 時 / 3 時 / 直到電力耗盡 / 關閉 / 結束）
# 流程：按下 → 進入「待命」並保護闔蓋 → 你闔上筆電才開始倒數 → 時間到若你人不在就讓筆電睡眠
#       ‧ 按下後 5 分鐘沒闔上 → 自動取消並還原
#       ‧ 倒數中你掀開筆電 → 立即還原並通知（含本次續跑時長）
#       ‧ 開機時若上次沒正常結束 → 自動還原並通知
# 只改 powercfg「闔蓋動作」+「電池閒置睡眠」，不需系統管理員權限。
# activity.log：每行 [動作]/[狀態] + 時間戳 + 電池/充電狀態；睡眠/喚醒由背景元件與主程式共同記錄。

$ErrorActionPreference = 'Stop'
$root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$marker = Join-Path $root 'state.on'
$errlog = Join-Path $root 'error.log'
$actlog = Join-Path $root 'activity.log'

# 讀電池/充電狀態（給每行 log 用；底層 GetSystemPowerStatus，每次即時讀）
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class KA_Pwr {
    [StructLayout(LayoutKind.Sequential)]
    struct SPS { public byte ac; public byte flag; public byte pct; public byte sys; public int t1; public int t2; }
    [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out SPS s);
    public static string Tag() {
        SPS s;
        if (!GetSystemPowerStatus(out s)) return "電源未知";
        if (s.ac == 1) return "插電";
        if (s.pct <= 100) return "電池 " + s.pct + "%";
        return "電池";
    }
}
'@
} catch {}
function Get-PowerTag { try { return [KA_Pwr]::Tag() } catch { return '' } }

# 兩類：[動作]=程式或你觸發的操作、[狀態]=偵測到的電腦狀態；每行結尾附電池/充電
function Log([string]$cat, [string]$m) {
    try {
        if (-not (Test-Path $actlog)) {
            Add-Content -Path $actlog -Value '# Claude 續跑模式 活動記錄　—　[動作]=程式/你觸發的操作、[狀態]=電腦狀態；每行結尾｜後為電池/充電狀態' -Encoding UTF8
        }
        if ((Get-Item $actlog).Length -gt 262144) {
            Set-Content -Path $actlog -Value (Get-Content $actlog -Tail 300 -Encoding UTF8) -Encoding UTF8   # 超過 256KB 只留最後 300 行
        }
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $tag = Get-PowerTag
        $line = if ($tag) { "[$ts] [$cat] $m  ｜$tag" } else { "[$ts] [$cat] $m" }
        Add-Content -Path $actlog -Value $line -Encoding UTF8
    } catch {}
}

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # ---- DPI 感知（修好選單/圖示在高縮放螢幕上的模糊）----
    Add-Type -Namespace KA -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
    try { [void][KA.Dpi]::SetProcessDPIAware() } catch {}
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch {}
    try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}

    # ---- 單一實例 ----
    $mtxCreated = $false
    $script:mtx = New-Object System.Threading.Mutex($true, 'Global\ClaudeKeepAwakeTray', [ref]$mtxCreated)
    if (-not $mtxCreated) { return }

    # ---- 電源設定核心（記錄實際改了哪兩個設定，當安全佐證）----
    $SUB = 'SUB_BUTTONS'
    $LidGuid = '5ca83367-6e45-459f-a27b-476b1d01c936'    # 闔蓋動作；勿用 $LID（會與 $lid 大小寫撞名）
    function Set-Lid([int]$v) {
        powercfg /setacvalueindex SCHEME_CURRENT $SUB $LidGuid $v | Out-Null
        powercfg /setdcvalueindex SCHEME_CURRENT $SUB $LidGuid $v | Out-Null
    }
    function Enable-KeepAwake {
        Set-Lid 0
        powercfg /change standby-timeout-dc 0 | Out-Null
        powercfg /setactive SCHEME_CURRENT | Out-Null
        Log '動作' '套用電源設定：闔蓋動作＝不做任何動作、電池閒置＝永不睡眠'
    }
    function Restore-Normal {
        Set-Lid 1
        powercfg /change standby-timeout-dc 5 | Out-Null
        powercfg /setactive SCHEME_CURRENT | Out-Null
        Log '動作' '還原電源設定：闔蓋動作＝睡眠、電池閒置＝5 分鐘睡眠'
    }

    # ---- Windows 11 原生 toast ----
    $appId = 'ClaudeCode.KeepAwake'
    $regBase = "HKCU:\SOFTWARE\Classes\AppUserModelId\$appId"
    if (-not (Test-Path $regBase)) { New-Item -Path $regBase -Force | Out-Null }
    New-ItemProperty -Path $regBase -Name 'DisplayName' -Value 'Claude 續跑模式' -PropertyType String -Force | Out-Null
    function Show-Toast([string]$title, [string]$body) {
        $esc = { param($s) $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' }
        try {
            $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
            $xml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$(& $esc $title)</text>
      <text>$(& $esc $body)</text>
    </binding>
  </visual>
</toast>
"@
            $doc = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
            $doc.LoadXml($xml)
            $t = [Windows.UI.Notifications.ToastNotification]::new($doc)
            $t.Group = 'ClaudeKeepAwake'; $t.Tag = 'state'
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($t)
        } catch {}
    }

    # ---- 系統匣圖示：coffee.png（Twemoji ☕，CC-BY 4.0）彩色=續跑 / 灰階=關閉；找不到就退回手繪杯 ----
    function New-CupIcon([bool]$on) {
        $w = [Math]::Max(32, [System.Windows.Forms.SystemInformation]::SmallIconSize.Width * 2)
        $bmp = New-Object System.Drawing.Bitmap $w, $w
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $u = $w / 24.0
        $disc = if ($on) { [System.Drawing.Color]::FromArgb(255, 34, 197, 94) } else { [System.Drawing.Color]::FromArgb(255, 120, 124, 132) }
        $g.FillEllipse((New-Object System.Drawing.SolidBrush $disc), [single](0.2 * $u), [single](0.2 * $u), [single](23.6 * $u), [single](23.6 * $u))
        $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([single](2.2 * $u))
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pts = [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF([single](6 * $u), [single](9 * $u))),
            (New-Object System.Drawing.PointF([single](17 * $u), [single](9 * $u))),
            (New-Object System.Drawing.PointF([single](15.2 * $u), [single](18.5 * $u))),
            (New-Object System.Drawing.PointF([single](7.8 * $u), [single](18.5 * $u)))
        )
        $g.FillPolygon($white, $pts)
        $g.DrawArc($pen, [single](16 * $u), [single](9.5 * $u), [single](5.5 * $u), [single](5.5 * $u), -80, 160)
        if ($on) {
            $g.DrawLine($pen, [single](9.5 * $u), [single](4 * $u), [single](9.5 * $u), [single](7.5 * $u))
            $g.DrawLine($pen, [single](13.5 * $u), [single](4 * $u), [single](13.5 * $u), [single](7.5 * $u))
        }
        $g.Dispose()
        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    }
    function New-CoffeeIcon([bool]$on) {
        $png = Join-Path $root 'coffee.png'
        if (-not (Test-Path $png)) { return New-CupIcon $on }
        try {
            $w = [Math]::Max(32, [System.Windows.Forms.SystemInformation]::SmallIconSize.Width * 2)
            $bmp = New-Object System.Drawing.Bitmap $w, $w
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)
            $src = New-Object System.Drawing.Bitmap $png
            $dr = New-Object System.Drawing.Rectangle 0, 0, $w, $w
            if ($on) {
                $g.DrawImage($src, $dr, 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel)
            } else {
                $cm = New-Object System.Drawing.Imaging.ColorMatrix
                $cm.Matrix00 = 0.30; $cm.Matrix01 = 0.30; $cm.Matrix02 = 0.30
                $cm.Matrix10 = 0.59; $cm.Matrix11 = 0.59; $cm.Matrix12 = 0.59
                $cm.Matrix20 = 0.11; $cm.Matrix21 = 0.11; $cm.Matrix22 = 0.11
                $cm.Matrix33 = 0.85
                $ia = New-Object System.Drawing.Imaging.ImageAttributes
                $ia.SetColorMatrix($cm)
                $g.DrawImage($src, $dr, 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
            }
            $src.Dispose(); $g.Dispose()
            return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        } catch { return New-CupIcon $on }
    }
    $script:icoOn  = New-CoffeeIcon $true
    $script:icoOff = New-CoffeeIcon $false

    # ---- 狀態機：off → armed（待闔上）→ counting（倒數中）----
    $script:st = @{ Phase = 'off'; Mode = $null; Minutes = 0; Expiry = $null; ArmStart = $null; Start = $null }
    $script:prevLid = $null
    $script:prevResume = 0
    $script:lastBeat = $null
    $script:armTimeoutMin = 5

    # ---- Lid 感測器 + 閒置偵測 + 睡眠/喚醒偵測（睡眠瞬間直接寫 log，因主程式那時已凍結）----
    $script:lid = $null
    try {
        Add-Type -ReferencedAssemblies 'System.Windows.Forms' -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class KA_LidWatcher : NativeWindow, IDisposable {
    [DllImport("user32.dll", SetLastError=true)]
    static extern IntPtr RegisterPowerSettingNotification(IntPtr h, ref Guid g, uint flags);
    [DllImport("user32.dll")]
    static extern bool UnregisterPowerSettingNotification(IntPtr h);
    [DllImport("user32.dll")]
    static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("kernel32.dll")]
    static extern bool GetSystemPowerStatus(out SPS s);
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential)]
    struct SPS { public byte ac; public byte flag; public byte pct; public byte sys; public int t1; public int t2; }
    public static double IdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return 0;
        uint now = (uint)Environment.TickCount;
        return (now - lii.dwTime) / 1000.0;
    }
    static string PwTag() {
        SPS s;
        if (!GetSystemPowerStatus(out s)) return "電源未知";
        if (s.ac == 1) return "插電";
        if (s.pct <= 100) return "電池 " + s.pct + "%";
        return "電池";
    }
    const int WM_POWERBROADCAST = 0x0218;
    const int PBT_POWERSETTINGCHANGE = 0x8013;
    const int PBT_APMSUSPEND = 0x0004;
    const int PBT_APMRESUMESUSPEND = 0x0007;
    const int PBT_APMRESUMEAUTOMATIC = 0x0012;
    static Guid LID = new Guid("ba3e0f4d-b817-4094-a2d1-d56379e6a0f3");
    [StructLayout(LayoutKind.Sequential)]
    struct PBS { public Guid PowerSetting; public uint DataLength; public byte Data; }
    IntPtr hReg = IntPtr.Zero;
    public int LidState = -1;             // 1=開, 0=闔
    public int ResumeCount = 0;           // 每次從睡眠喚醒 +1
    public DateTime SuspendAt = DateTime.MinValue;
    public DateTime ResumeAt = DateTime.MinValue;
    public string LogPath = "";
    void WriteLog(string cat, string msg) {
        try {
            if (string.IsNullOrEmpty(LogPath)) return;
            string line = "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] [" + cat + "] " + msg + "  ｜" + PwTag() + "\r\n";
            System.IO.File.AppendAllText(LogPath, line, new System.Text.UTF8Encoding(false));
        } catch {}
    }
    public KA_LidWatcher() {
        this.CreateHandle(new CreateParams());
        hReg = RegisterPowerSettingNotification(this.Handle, ref LID, 0);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_POWERBROADCAST) {
            int ev = m.WParam.ToInt32();
            if (ev == PBT_POWERSETTINGCHANGE && m.LParam != IntPtr.Zero) {
                PBS s = (PBS)Marshal.PtrToStructure(m.LParam, typeof(PBS));
                if (s.PowerSetting == LID) LidState = (int)s.Data;
            } else if (ev == PBT_APMSUSPEND) {
                SuspendAt = DateTime.Now;
                WriteLog("狀態", "電腦進入睡眠（即將睡眠）");
            } else if (ev == PBT_APMRESUMEAUTOMATIC || ev == PBT_APMRESUMESUSPEND) {
                ResumeAt = DateTime.Now; ResumeCount++;
            }
        }
        base.WndProc(ref m);
    }
    public void Dispose() {
        if (hReg != IntPtr.Zero) { UnregisterPowerSettingNotification(hReg); hReg = IntPtr.Zero; }
        try { this.DestroyHandle(); } catch {}
    }
}
'@
        $script:lid = New-Object KA_LidWatcher
        $script:lid.LogPath = $actlog
    } catch { $script:lid = $null }

    function Get-Lid { if ($script:lid) { return [int]$script:lid.LidState } else { return -1 } }
    function Mode-Label([string]$m) { switch ($m) { '30m' { '30 分鐘' } '1h' { '1 小時' } '3h' { '3 小時' } 'batt' { '直到電力耗盡' } default { $m } } }
    function Elapsed-Min { if ($script:st.Start) { return [int][math]::Round(([DateTime]::Now - $script:st.Start).TotalMinutes) } else { return 0 } }

    # ---- 系統匣 + 選單 ----
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = $script:icoOff
    $ni.Text = 'Claude 續跑：關閉'
    $ni.Visible = $true
    $script:ni = $ni

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miStatus = $menu.Items.Add('狀態：關閉'); $miStatus.Enabled = $false
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $mi30   = $menu.Items.Add('開啟　30 分鐘（預設）')
    $mi60   = $menu.Items.Add('開啟　1 小時')
    $mi180  = $menu.Items.Add('開啟　3 小時')
    $miBatt = $menu.Items.Add('開啟　直到電力耗盡')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miOff  = $menu.Items.Add('關閉（還原正常）')
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miExit = $menu.Items.Add('結束此程式')
    $ni.ContextMenuStrip = $menu

    function Update-UI {
        switch ($script:st.Phase) {
            'armed' {
                $ni.Icon = $script:icoOn
                $lbl = Mode-Label $script:st.Mode
                $ni.Text = "Claude 續跑：待命 · 闔上後倒數 $lbl"
                $miStatus.Text = "狀態：待你闔上筆電後開始倒數（$lbl）"
            }
            'counting' {
                $ni.Icon = $script:icoOn
                if ($script:st.Expiry) {
                    $rem = [int][math]::Ceiling(($script:st.Expiry - [DateTime]::Now).TotalMinutes)
                    if ($rem -lt 0) { $rem = 0 }
                    $ni.Text = "Claude 續跑：倒數中 · 剩 $rem 分"
                    $miStatus.Text = "狀態：倒數中 · 約 $rem 分鐘後睡眠"
                } else {
                    $ni.Text = 'Claude 續跑：續跑中 · 直到電力耗盡'
                    $miStatus.Text = '狀態：續跑中 · 直到電力耗盡'
                }
            }
            default {
                $ni.Icon = $script:icoOff
                $ni.Text = 'Claude 續跑：關閉'
                $miStatus.Text = '狀態：關閉'
            }
        }
        $on = ($script:st.Phase -ne 'off')
        $mi30.Checked   = ($on -and $script:st.Mode -eq '30m')
        $mi60.Checked   = ($on -and $script:st.Mode -eq '1h')
        $mi180.Checked  = ($on -and $script:st.Mode -eq '3h')
        $miBatt.Checked = ($on -and $script:st.Mode -eq 'batt')
    }

    function Reset-State {
        $script:st.Phase = 'off'; $script:st.Mode = $null; $script:st.Minutes = 0
        $script:st.Expiry = $null; $script:st.ArmStart = $null; $script:st.Start = $null
        $script:lastBeat = $null
        if (Test-Path $marker) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }
    }

    function Start-Count {
        $script:st.Phase = 'counting'
        $script:st.Expiry = if ($script:st.Minutes -gt 0) { [DateTime]::Now.AddMinutes($script:st.Minutes) } else { $null }
        $script:lastBeat = [DateTime]::Now
        Update-UI
        $lbl = Mode-Label $script:st.Mode
        if ($script:st.Minutes -gt 0) {
            Show-Toast "Claude 續跑：已闔上，開始倒數（$lbl）⏳" '時間到、若你人不在就讓筆電睡眠；提早掀開會立即還原。'
            Log '動作' ("開始倒數 {0} 分鐘，預計 {1} 讓筆電睡眠" -f $script:st.Minutes, $script:st.Expiry.ToString('HH:mm'))
        } else {
            Show-Toast 'Claude 續跑：已闔上，持續續跑中' '會跑到電量過低自動休眠；掀開或手動可提早關閉。'
            Log '動作' '持續續跑中，直到電量過低才休眠'
        }
    }

    function Arm([string]$mode, [int]$minutes) {
        Enable-KeepAwake
        $script:st.Phase = 'armed'; $script:st.Mode = $mode; $script:st.Minutes = $minutes
        $script:st.ArmStart = [DateTime]::Now; $script:st.Start = [DateTime]::Now; $script:st.Expiry = $null
        Set-Content -Path $marker -Value $mode -Encoding ASCII
        Update-UI
        $lbl = Mode-Label $mode
        Show-Toast "Claude 續跑：已開啟（$lbl）✅" '闔上筆電後開始倒數；5 分鐘內沒闔上會自動取消並還原。'
        Log '動作' "開啟續跑：$lbl（等你闔上筆電後開始倒數）"
        # 已經闔著（clamshell）或沒有 lid 感測器 → 立即開始倒數
        if ((Get-Lid) -eq 0 -or (-not $script:lid)) { Start-Count }
    }

    function Cancel-Arm {
        Restore-Normal
        Reset-State
        Update-UI
        Show-Toast 'Claude 續跑：已自動取消' '你 5 分鐘內沒有闔上筆電，已取消續跑並還原設定。'
        Log '動作' '超過 5 分鐘沒闔上，自動取消'
    }

    function Turn-Off([string]$reason) {
        $mins = Elapsed-Min
        Restore-Normal
        Reset-State
        Update-UI
        switch ($reason) {
            'manual' { Show-Toast 'Claude 續跑：已關閉' "本次續跑約 $mins 分鐘，電源設定已還原正常。"; Log '動作' ("你手動關閉續跑（本次續跑 {0} 分）" -f $mins) }
            'lid'    { Show-Toast 'Claude 續跑：偵測到你掀開筆電 👋' "本次續跑約 $mins 分鐘，已成功還原電源設定 ✅。"; Log '動作' ("結束續跑（本次續跑 {0} 分）" -f $mins) }
            default  { }
        }
    }

    function Expire-Timer {
        $mins = Elapsed-Min
        $planned = $script:st.Expiry
        $lidClosed = ((Get-Lid) -eq 0)
        $idle = try { [KA_LidWatcher]::IdleSeconds() } catch { 999 }
        Restore-Normal
        Reset-State
        Update-UI
        $willSleep = ($lidClosed -and $idle -ge 60)
        Log '狀態' ("倒數到期：預定 {0}、實際 {1}、筆電闔上={2}、閒置 {3} 秒" -f $planned.ToString('HH:mm'), (Get-Date -Format 'HH:mm'), $(if ($lidClosed) { '是' } else { '否' }), [int]$idle)
        if ($willSleep) {
            Show-Toast "Claude 續跑：時間到（跑了約 $mins 分）💤" '已還原電源設定，讓筆電進入睡眠。'
            Log '動作' ("時間到，依預定讓電腦進入睡眠（本次續跑 {0} 分）" -f $mins)
            Start-Sleep -Milliseconds 700
            [void][System.Windows.Forms.Application]::SetSuspendState([System.Windows.Forms.PowerState]::Suspend, $false, $false)
        } else {
            Show-Toast "Claude 續跑：時間到（跑了約 $mins 分）✅" '偵測到你還在使用（筆電掀開／剛有操作），只還原設定、沒讓它睡。'
            Log '動作' ("時間到，但你還在使用，未讓電腦睡眠（本次續跑 {0} 分）" -f $mins)
        }
    }

    # ---- 事件 ----
    $ni.add_MouseClick({ param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            if ($script:st.Phase -eq 'off') { Arm '30m' 30 } else { Turn-Off 'manual' }
        }
    })
    $menu.add_Opening({ Update-UI })
    $mi30.add_Click({ Arm '30m' 30 })
    $mi60.add_Click({ Arm '1h' 60 })
    $mi180.add_Click({ Arm '3h' 180 })
    $miBatt.add_Click({ Arm 'batt' 0 })
    $miOff.add_Click({ if ($script:st.Phase -ne 'off') { Turn-Off 'manual' } })
    $miExit.add_Click({
        Log '動作' '你從選單結束了程式'
        try { $script:timer.Stop() } catch {}
        if ($script:st.Phase -ne 'off') { Restore-Normal }
        Reset-State
        $ni.Visible = $false; $ni.Dispose()
        if ($script:lid) { $script:lid.Dispose() }
        [System.Windows.Forms.Application]::ExitThread()
    })

    # ---- 主計時器（每 5 秒）：喚醒偵測、闔蓋/掀蓋、arm 逾時、倒數到期、續跑中心跳 ----
    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = 5000
    $script:timer.add_Tick({
        # 從睡眠喚醒（睡眠那筆由背景元件在 suspend 當下已寫入）
        if ($script:lid -and $script:lid.ResumeCount -gt $script:prevResume) {
            $script:prevResume = $script:lid.ResumeCount
            if ($script:lid.SuspendAt -ne [DateTime]::MinValue -and $script:lid.ResumeAt -gt $script:lid.SuspendAt) {
                Log '狀態' ("電腦已從睡眠喚醒（睡了 {0} 分）" -f [int][math]::Round(($script:lid.ResumeAt - $script:lid.SuspendAt).TotalMinutes))
            } else {
                Log '狀態' '電腦已從睡眠喚醒'
            }
        }
        $cur = Get-Lid
        if ($cur -ge 0 -and $null -eq $script:prevLid) { $script:prevLid = $cur }
        $opened = ($cur -eq 1 -and $script:prevLid -eq 0)
        if ($cur -ge 0) { $script:prevLid = $cur }
        switch ($script:st.Phase) {
            'armed' {
                if ($cur -eq 0) { Log '狀態' '偵測到筆電闔上'; Start-Count }
                elseif (([DateTime]::Now - $script:st.ArmStart).TotalMinutes -ge $script:armTimeoutMin) { Cancel-Arm }
            }
            'counting' {
                if ($opened) { Log '狀態' '偵測到筆電掀開'; Turn-Off 'lid' }
                elseif ($script:st.Expiry -and [DateTime]::Now -ge $script:st.Expiry) { Expire-Timer }
                else {
                    if (($null -eq $script:lastBeat) -or (([DateTime]::Now - $script:lastBeat).TotalMinutes -ge 15)) {
                        $script:lastBeat = [DateTime]::Now
                        $rem = if ($script:st.Expiry) { "剩 $([int][math]::Ceiling(($script:st.Expiry - [DateTime]::Now).TotalMinutes)) 分" } else { '直到電力耗盡' }
                        Log '狀態' ("續跑中…（{0}）" -f $rem)
                    }
                    Update-UI
                }
            }
        }
    })
    $script:timer.Start()

    # ---- 開機還原：上次若沒正常結束（marker 存在）→ 還原 + 通知 ----
    if (Test-Path $marker) {
        Restore-Normal
        Remove-Item $marker -Force -ErrorAction SilentlyContinue
        Show-Toast 'Claude 續跑：開機自動還原 ✅' '上次結束時仍在續跑模式，已幫你還原正常。'
        Log '動作' '開機發現上次未正常結束，已自動還原設定'
    }
    Update-UI
    Log '動作' '程式啟動，待命中'
    Log '狀態' ("筆電開合感測器：{0}" -f $(if ($script:lid) { '正常' } else { '無法讀取（將以「按下即倒數」運作）' }))

    [System.Windows.Forms.Application]::add_ApplicationExit({ try { if ($script:st.Phase -ne 'off') { Restore-Normal } } catch {} })
    [System.Windows.Forms.Application]::Run()
}
catch {
    $m = "$(Get-Date -Format s)  $($_.Exception.Message)`r`n$($_.ScriptStackTrace)`r`n"
    Add-Content -Path $errlog -Value $m -Encoding UTF8
}

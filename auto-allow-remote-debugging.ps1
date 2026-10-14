# auto-allow-remote-debugging.ps1   (v5)
#
# 自动点击 Edge / Chrome 的 "Allow remote debugging?"（允许远程调试）原生授权弹窗。
#
# 派生关系:
#   v3 = UIA AddStructureChangedEventHandler + 10s 兜底扫描
#        （PS 5.1 下脚本块回调从线程池投递，实测不触发 => 实际全靠兜底扫描）
#   v4 = 纯 Win32 SetWinEventHook + 自泵消息队列，无兜底；回调是 PowerShell 脚本块委托
#   v5 = v4 的触发思路 + v3 的兜底扫描，并把触发/泵消息整条链路下沉到 C#
#
# 相对 v4 的实质改动（以及为什么）:
#   1. 回调改为纯 C# 委托，不再用 PowerShell 脚本块当 WinEventDelegate。
#      v3 死于"脚本块回调不被调用"，v4 把同一个风险从 UIA 事件搬到了 WinEvent 上。
#      C# 静态委托 + 静态字段传状态 => 这个失效模式由构造消除。
#   2. 保留低频兜底扫描（默认 30s）。v4 删掉兜底后，一次丢事件 = 永久不点。
#   3. 触发过滤不再用 idObject==OBJID_WINDOW（那只认顶层窗口），改为按 hwnd 反查 pid
#      并只认 msedge/chrome —— 弹窗即使是主窗口的子 HWND 也能触发，同时把
#      "全桌面任何窗口创建都来一次全量扫描" 的噪声砍掉。
#   4. 同时挂 EVENT_OBJECT_SHOW（0x8002），覆盖"窗口先建好、后显示"的场景。
#   5. 触发后首扫未命中，400ms 后再扫一次（窗口已创建但 UIA 子元素还没长出来的竞态）。
#   6. 日志带毫秒 + 触发源，便于实测延迟；-Probe 会把浏览器 chrome UI 的控件清单
#      打出来，用来发现真实的本地化标题/按钮文案（别猜）。
#   7. 中英名称表可分别启用（-Texts zh|en|both），方便分机器对照测试。
#
# 实测验证 (Edge 155.0.4283.45, 2026-10):
#   en-US 机器: CLICKED 'Allow' dialog='Allow remote debugging?'，事件触发到点击 777~906ms。
#   zh-CN 机器: CLICKED '允许' dialog='是否允许远程调试?'。独立因果证据 —— CDP 握手被待授权
#     弹窗挡住 65s，点击后 72ms 就连上（Browser.getVersion 返回 Edg/155.0.4283.45）。
#   触发条件备注: 全新 profile + 显式 --remote-debugging-port 时 Edge 直接放行 CDP、不弹框；
#     只有"记住过远程调试"的 profile（命令行无 flag，但 DevToolsActivePort 存在、端口在听）才弹框。
#     判据: CDP 握手是否悬停 = 是否存在待授权弹窗，无需截图。
#   中文文案取自 Edge 语言包 zh-CN.pak: 标题 = 资源 12900，否定按钮 = 12906，
#     肯定按钮 12905 经 alias 表指向资源 7844 —— 不是猜的，并已由实机 UIA 逐字证实。
#
# 性能设计（继承 v1/v2/v3 的实测结论）:
#   * 空闲时不轮询，只等消息队列 => 空闲 ~0% CPU。
#   * 扫描本意是只遍历"非渲染器子树"（按类名跳过 Chrome_RenderWidgetHostHWND）。
#     对 Chromium 窗口做全树 UIA 遍历会强迫它维护完整无障碍树，浏览器侧 CPU 会飙到
#     47%（v1 实测）—— 这条设计意图绝不能改回去。
#
#   !! 已知限制（Edge 155 实测，尚未修）:
#      Edge 155 的 Chrome_WidgetWin_1 直接子节点只有 'Intermediate D3D Window' 和
#      'BrowserRootView'，不再出现 Chrome_RenderWidgetHostHWND => 上面那个类名剪枝
#      恒为真，扫描实际会伸进网页内容（ControlType.Document 子树）。后果:
#        (a) 每次扫描都要遍历活跃标签页的 DOM，CPU 开销回到 v2 量级；
#        (b) 理论上，若某网页同时存在同名 Text 与同名 Button，Invoke() 可能点到网页元素。
#      v2/v3 用的是同一个剪枝，所以这不是 v5 引入的回归，而是继承来的。
#      修法（须实测后再合入）: 改用手动 ControlView 遍历，在 ControlType.Document 处
#      剪掉整棵子树 —— 该判据不依赖类名，跨 Chromium 版本稳定。
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File auto-allow-remote-debugging.ps1
#   powershell -ExecutionPolicy Bypass -File auto-allow-remote-debugging.ps1 -Texts en -MaxSeconds 60
#   powershell -ExecutionPolicy Bypass -File auto-allow-remote-debugging.ps1 -Texts zh -Probe -MaxSeconds 60
# 停止: Ctrl+C
#
# 安全提示: 运行本脚本 = 任何以你用户身份运行的进程都能静默取得浏览器完全控制权，
#           请仅在可接受该风险的机器上使用。
#
# 注意: 文件含非 ASCII 字符，必须以 UTF-8 with BOM 保存，否则 PS 5.1 按 GBK 误读。

param(
    # 启用哪套本地化名称表
    [ValidateSet('both', 'zh', 'en')][string]$Texts = 'both',
    # 覆盖对话框标题 / 按钮名的精确匹配列表（不传则用内置表）
    [string[]]$DialogTexts,
    [string[]]$ButtonTexts,
    # 兜底扫描间隔（秒）；0 = 关闭兜底（不建议）
    [int]$FallbackSeconds = 30,
    # 两次扫描之间的最小间隔（毫秒），用于合并突发事件
    [int]$MinScanIntervalMs = 200,
    # 触发后首扫未命中，多久再扫一次（毫秒）；0 = 不重试
    [int]$RetryAfterMs = 400,
    # 跑满 N 秒后自动退出（0 = 一直跑）；供自动化测试用
    [int]$MaxSeconds = 0,
    # 只记录"会点哪个"，不真的点
    [switch]$DryRun,
    # 把浏览器 chrome UI 的控件清单写进日志（用于发现真实文案）
    [switch]$Probe,
    # 日志文件；默认 %TEMP%\pi-auto-allow.log
    [string]$LogFile,
    # 单实例互斥体名
    [string]$MutexName = 'Global\pi-auto-allow-remote-debugging'
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# ==================== P/Invoke + 事件链路（全在 C#） ====================
$win32 = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class WinEventApi {
    public const uint EVENT_OBJECT_CREATE  = 0x8000;
    public const uint EVENT_OBJECT_DESTROY = 0x8001;
    public const uint EVENT_OBJECT_SHOW    = 0x8002;
    public const uint WINEVENT_OUTOFCONTEXT   = 0x0000;
    public const uint WINEVENT_SKIPOWNPROCESS = 0x0002;
    public const uint PM_REMOVE = 0x0001;

    public delegate void WinEventDelegate(
        IntPtr hWinEventHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);

    [DllImport("user32.dll")]
    public static extern IntPtr SetWinEventHook(
        uint eventMin, uint eventMax, IntPtr hmodWinEventProc,
        WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);

    [DllImport("user32.dll")]
    public static extern bool UnhookWinEvent(IntPtr hWinEventHook);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int pt_x;
        public int pt_y;
    }

    [DllImport("user32.dll")]
    public static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd,
        uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

    [DllImport("user32.dll")]
    public static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    public static extern IntPtr DispatchMessage(ref MSG lpMsg);

    // ---- 状态：回调写、PowerShell 读。同一线程，无需加锁；volatile 仅作形式保证 ----
    public static volatile int EventFlag = 0;
    public static volatile uint LastEventType = 0;
    public static volatile uint LastEventPid = 0;
    public static readonly HashSet<int> PidFilter = new HashSet<int>();

    // 委托与 hook 句柄必须保活，否则 GC 之后 hook 静默失效
    private static WinEventDelegate _cb = null;
    private static IntPtr _hook = IntPtr.Zero;

    // 回调由系统投递到"调用 SetWinEventHook 的那个线程"，也就是我们自己在泵消息的主线程
    private static void OnEventRaw(IntPtr hHook, uint eventType, IntPtr hwnd,
                                   int idObject, int idChild, uint thread, uint ms) {
        if (eventType == EVENT_OBJECT_DESTROY) return;
        if (hwnd == IntPtr.Zero) return;
        uint pid;
        if (GetWindowThreadProcessId(hwnd, out pid) == 0) return;
        if (!PidFilter.Contains((int)pid)) return;
        LastEventType = eventType;
        LastEventPid = pid;
        EventFlag = 1;
    }

    public static IntPtr Install() {
        _cb = new WinEventDelegate(OnEventRaw);
        _hook = SetWinEventHook(EVENT_OBJECT_CREATE, EVENT_OBJECT_SHOW, IntPtr.Zero, _cb,
                                0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
        return _hook;
    }

    public static void Uninstall() {
        if (_hook != IntPtr.Zero) { UnhookWinEvent(_hook); _hook = IntPtr.Zero; }
        _cb = null;
    }

    // 泵一次消息队列；返回处理的消息条数。
    // WINEVENT_OUTOFCONTEXT 的回调靠系统投递到本线程队列，必须 Translate+Dispatch 才会执行。
    public static int PumpOnce() {
        int n = 0;
        MSG msg;
        while (PeekMessage(out msg, IntPtr.Zero, 0, 0, PM_REMOVE)) {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
            n++;
        }
        return n;
    }
}
'@
Add-Type -TypeDefinition $win32 -ErrorAction Stop

# ==================== 名称表 ====================
$nameTable = @{
    en = @{
        dlg = @('Allow remote debugging?')
        btn = @('Allow')
    }
    zh = @{
        # 实证取自 Edge 155.0.4283.45 的 Locales\zh-CN.pak（非猜测，资源 ID 已核对）：
        #   ID 12900          = '是否允许远程调试?'   ← 对话框标题（注意是半角 '?'）
        #   ID 12905 → 7844   = '允许'               ← 肯定按钮，与 en-US 'Allow' 复用同一资源 ID
        # 全角 '？' 版本在资源包中不存在（已查证 COUNT=0），故不再列入。
        dlg = @('是否允许远程调试?')
        btn = @('允许')
    }
}
switch ($Texts) {
    'en' { $dlgNames = $nameTable.en.dlg; $btnNames = $nameTable.en.btn }
    'zh' { $dlgNames = $nameTable.zh.dlg; $btnNames = $nameTable.zh.btn }
    default { $dlgNames = @($nameTable.en.dlg) + @($nameTable.zh.dlg); $btnNames = @($nameTable.en.btn) + @($nameTable.zh.btn) }
}
if ($DialogTexts) { $dlgNames = $DialogTexts }
if ($ButtonTexts) { $btnNames = $ButtonTexts }

# ==================== 基础设置 ====================
$root = [Windows.Automation.AutomationElement]::RootElement

$mutex = New-Object System.Threading.Mutex($false, $MutexName)
if (-not $mutex.WaitOne(0)) { Write-Host "Another instance is already running ($MutexName). Exit."; exit 0 }

if (-not $LogFile) { $LogFile = Join-Path $env:TEMP 'pi-auto-allow.log' }
function Log($msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

Log ("v5 start: Texts=$Texts fallback=${FallbackSeconds}s retry=${RetryAfterMs}ms max=${MaxSeconds}s dryrun=$DryRun probe=$Probe")
Log ("  dialog='{0}'  button='{1}'" -f ($dlgNames -join "', '"), ($btnNames -join "', '"))
Log ("  log=$LogFile")

# ==================== UIA 条件 ====================
$classCond = New-Object Windows.Automation.PropertyCondition(
    [Windows.Automation.AutomationElement]::ClassNameProperty, 'Chrome_WidgetWin_1')

$nameProp = [Windows.Automation.AutomationElement]::NameProperty
$typeProp = [Windows.Automation.AutomationElement]::ControlTypeProperty

# 用显式 AddCondition 而不是 `New-Object OrCondition($arr)`：
# 后者依赖 PowerShell 把数组拍平成 params 参数，且只有 1 个条件时 OrCondition 会抛异常。
function New-NameOrCond([string[]]$names, $prop) {
    $conds = @($names | ForEach-Object { New-Object Windows.Automation.PropertyCondition($prop, $_) })
    if ($conds.Count -eq 0) { return $null }
    if ($conds.Count -eq 1) { return $conds[0] }
    $or = New-Object Windows.Automation.OrCondition($conds[0], $conds[1])
    for ($i = 2; $i -lt $conds.Count; $i++) { [void]$or.AddCondition($conds[$i]) }
    return $or
}

$dlgCond = New-NameOrCond $dlgNames $nameProp
$btnTextCond = New-NameOrCond $btnNames $nameProp
$typeCond = New-Object Windows.Automation.PropertyCondition(
    $typeProp, [Windows.Automation.ControlType]::Button)
$btnCond = New-Object Windows.Automation.AndCondition($btnTextCond, $typeCond)

$walker = [Windows.Automation.TreeWalker]::ControlViewWalker

# 只在窗口的浏览器 chrome 子树里找（跳过渲染器内容）。
# 返回 @{Button=..; DialogText=..} 或 $null
function Test-Window($win) {
    $child = $walker.GetFirstChild($win)
    while ($null -ne $child) {
        try {
            if ($child.Current.ClassName -ne 'Chrome_RenderWidgetHostHWND') {
                $text = $null
                if ($dlgCond) { $text = $child.FindFirst([Windows.Automation.TreeScope]::Descendants, $dlgCond) }
                if ($text) {
                    $btn = $child.FindFirst([Windows.Automation.TreeScope]::Descendants, $btnCond)
                    if ($btn) {
                        # 必须在 Invoke 之前把名字取出来：点完弹窗就销毁，元素随即失效（Current.Name 会读成空串）
                        return [pscustomobject]@{
                            Button     = $btn
                            ButtonText = $btn.Current.Name
                            DialogText = $text.Current.Name
                        }
                    }
                }
            }
        } catch { }
        $child = $walker.GetNextSibling($child)
    }
    return $null
}

function Get-BrowserWindows {
    $out = @()
    try {
        foreach ($w in $root.FindAll([Windows.Automation.TreeScope]::Children, $classCond)) {
            $proc = Get-Process -Id $w.Current.ProcessId -ErrorAction SilentlyContinue
            if (-not $proc -or ($proc.Name -ne 'msedge' -and $proc.Name -ne 'chrome')) { continue }
            $out += [pscustomobject]@{ Window = $w; Proc = $proc }
        }
    } catch { }
    return $out
}

function Update-KnownPids {
    [WinEventApi]::PidFilter.Clear()
    foreach ($p in (Get-Process -Name msedge, chrome -ErrorAction SilentlyContinue)) {
        [void][WinEventApi]::PidFilter.Add([int]$p.Id)
    }
}

# 扫一遍所有浏览器窗口；发现弹窗就点掉。返回是否点了。
function Scan-AndClick([string]$trigger) {
    $clicked = $false
    $sawBrowser = $false
    try {
        foreach ($bw in (Get-BrowserWindows)) {
            $sawBrowser = $true
            $hit = Test-Window $bw.Window
            if ($hit) {
                if ($DryRun) {
                    Log ("DRYRUN would click '{0}' (dialog='{1}' pid={2} trigger={3})" -f `
                            $hit.ButtonText, $hit.DialogText, $bw.Proc.Id, $trigger)
                    $clicked = $true
                }
                else {
                    ($hit.Button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke()
                    Log ("CLICKED '{0}' dialog='{1}' pid={2} trigger={3} at={4:HH:mm:ss.fff}" -f `
                            $hit.ButtonText, $hit.DialogText, $bw.Proc.Id, $trigger, (Get-Date))
                    $clicked = $true
                }
            }
        }
    } catch { }
    if (-not $clicked -and $sawBrowser) { Log ("  scan($trigger): browser windows present, no consent dialog") }
    return $clicked
}

# -Probe: 把浏览器 chrome UI 里的 Button / Text 控件清单写进日志（用于发现真实文案）
$script:lastProbeSig = ''
function Probe-ChromeUi([string]$tag) {
    $out = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($bw in (Get-BrowserWindows)) {
            $child = $walker.GetFirstChild($bw.Window)
            while ($null -ne $child) {
                try {
                    if ($child.Current.ClassName -ne 'Chrome_RenderWidgetHostHWND') {
                        foreach ($ct in @([Windows.Automation.ControlType]::Button, [Windows.Automation.ControlType]::Text)) {
                            $c = New-Object Windows.Automation.PropertyCondition($typeProp, $ct)
                            foreach ($e in $child.FindAll([Windows.Automation.TreeScope]::Descendants, $c)) {
                                try {
                                    $out.Add(('pid={0} {1}|{2}|{3}' -f $bw.Proc.Id,
                                            $ct.ProgrammaticName.Split('.')[-1], $e.Current.Name, $e.Current.ClassName))
                                } catch { }
                            }
                        }
                    }
                } catch { }
                $child = $walker.GetNextSibling($child)
            }
        }
    } catch { }
    if ($out.Count -eq 0) { return }
    $sig = ($out -join "`n")
    if ($sig -eq $script:lastProbeSig) { return }
    $script:lastProbeSig = $sig
    Log ("PROBE {0}: {1} elements" -f $tag, $out.Count)
    foreach ($l in $out) { Add-Content -Path $LogFile -Value ('    ' + $l) -ErrorAction SilentlyContinue }
}

# ==================== 装 hook ====================
Update-KnownPids
Log ("pid filter seeded with {0} browser process(es)" -f [WinEventApi]::PidFilter.Count)

$hook = [WinEventApi]::Install()
if ($hook -eq [IntPtr]::Zero) { Log "ERROR: SetWinEventHook failed."; exit 1 }
Log ("WinEventHook installed (handle: {0}), range CREATE..SHOW, pid-filtered" -f $hook)

# ==================== 主循环 ====================
$started = Get-Date
$lastPidRefresh = Get-Date
$lastScan = (Get-Date).AddSeconds(-86400)
$retryAt = $null

# 启动时先扫一次（处理脚本启动前就已弹出的弹窗）
if (Scan-AndClick 'startup') { Start-Sleep -Milliseconds 1500 }

try {
    while ($true) {
        [void][WinEventApi]::PumpOnce()

        $now = Get-Date

        # 定期刷新"哪些 pid 是浏览器"，让回调的 pid 过滤在浏览器后启动时也能跟上
        if (($now - $lastPidRefresh).TotalMilliseconds -ge 5000) { Update-KnownPids; $lastPidRefresh = $now }

        $trigger = $null
        if ([WinEventApi]::EventFlag -ne 0) {
            [WinEventApi]::EventFlag = 0
            $trigger = 'hook({0:x}@pid{1})' -f [WinEventApi]::LastEventType, [WinEventApi]::LastEventPid
        }
        elseif ($retryAt -and $now -ge $retryAt) {
            $trigger = 'retry'
            $retryAt = $null
        }
        elseif ($FallbackSeconds -gt 0 -and ($now - $lastScan).TotalSeconds -ge $FallbackSeconds) {
            $trigger = 'fallback'
        }

        if ($trigger) {
            if ($Probe) { Probe-ChromeUi $trigger }
            if (($now - $lastScan).TotalMilliseconds -ge $MinScanIntervalMs) {
                $lastScan = $now
                if (Scan-AndClick $trigger) {
                    Start-Sleep -Milliseconds 1500
                    $retryAt = $null
                    $lastScan = Get-Date
                }
                elseif ($trigger -ne 'retry' -and $RetryAfterMs -gt 0) {
                    # 窗口刚创建、UIA 子元素还没长出来 => 稍后再试一次
                    $retryAt = (Get-Date).AddMilliseconds($RetryAfterMs)
                }
            }
            elseif (-not $retryAt) {
                $retryAt = $now.AddMilliseconds($MinScanIntervalMs)
            }
        }

        if ($MaxSeconds -gt 0 -and ((Get-Date) - $started).TotalSeconds -ge $MaxSeconds) {
            Log "Reached MaxSeconds=$MaxSeconds, exiting."
            break
        }

        Start-Sleep -Milliseconds 50
    }
}
finally {
    [WinEventApi]::Uninstall()
    Log "v5 stop."
}

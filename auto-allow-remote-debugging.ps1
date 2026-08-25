# auto-allow-remote-debugging.ps1  (v3 - event-driven, near-zero idle cost)
# 后台监听 Edge/Chrome 的 "Allow remote debugging?" 弹窗并自动点击 Allow。
# 用法:  powershell -ExecutionPolicy Bypass -File auto-allow-remote-debugging.ps1
# 停止:  Ctrl+C，或任务管理器结束对应 powershell 进程
# 安全提示: 运行本脚本 = 任何以你用户身份运行的进程都能静默取得浏览器完全控制权，
#           请仅在可接受该风险的机器上使用。
#
# 性能设计（实测）:
#   v1 500ms 全树轮询        : watcher ~17% CPU，且连带 msedge ~47% CPU
#   v2 跳过渲染器子树轮询    : watcher ~11% CPU，msedge ~7%
#   v3 结构变化事件驱动(本版): 空闲 ~0% CPU；实测 PS5.1 下 UIA 事件回调不可靠，
#       实际靠兜底扫描捕获，扫描间隔 10s → 最坏延迟 ~10s，空闲开销 ~0.6% CPU
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$root    = [Windows.Automation.AutomationElement]::RootElement
$dlgName = 'Allow remote debugging?'
$btnName = 'Allow'

# 单实例保护：已有同名 watcher 在跑就直接退出（任务计划 MultipleInstances=IgnoreNew 之外的双保险）
$mutex = New-Object System.Threading.Mutex($false, 'Global\pi-auto-allow-remote-debugging')
if (-not $mutex.WaitOne(0)) {
    Write-Host 'Another instance is already running. Exit.'
    exit 0
}

# 同时写控制台和日志文件，便于后台运行时观察
$logFile = Join-Path $env:TEMP 'pi-auto-allow.log'
function Log($msg) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $logFile -Value $line -ErrorAction SilentlyContinue
}

# Chromium 系浏览器主窗口类名都是 Chrome_WidgetWin_1
$classCond = New-Object Windows.Automation.PropertyCondition(
    [Windows.Automation.AutomationElement]::ClassNameProperty, 'Chrome_WidgetWin_1')

# 精确匹配"Allow"按钮 + Button 控件类型，防止误点网页上的同名按钮
$nameCond = New-Object Windows.Automation.PropertyCondition(
    [Windows.Automation.AutomationElement]::NameProperty, $btnName)
$typeCond = New-Object Windows.Automation.PropertyCondition(
    [Windows.Automation.AutomationElement]::ControlTypeProperty,
    [Windows.Automation.ControlType]::Button)
$btnCond = New-Object Windows.Automation.AndCondition($nameCond, $typeCond)
$textCond = New-Object Windows.Automation.PropertyCondition(
    [Windows.Automation.AutomationElement]::NameProperty, $dlgName)

$walker = [Windows.Automation.TreeWalker]::ControlViewWalker

# 只在窗口的浏览器 chrome 子树里找（跳过渲染器内容），返回 Allow 按钮或 $null
function Test-Window($win) {
    $child = $walker.GetFirstChild($win)
    while ($null -ne $child) {
        try {
            if ($child.Current.ClassName -ne 'Chrome_RenderWidgetHostHWND') {
                if ($child.FindFirst([Windows.Automation.TreeScope]::Descendants, $textCond)) {
                    return $child.FindFirst([Windows.Automation.TreeScope]::Descendants, $btnCond)
                }
            }
        } catch { }
        $child = $walker.GetNextSibling($child)
    }
    return $null
}

# 扫一遍所有浏览器窗口；发现弹窗就点掉。返回是否点了。
function Scan-AndClick {
    $clicked = $false
    try {
        $windows = $root.FindAll([Windows.Automation.TreeScope]::Children, $classCond)
        foreach ($w in $windows) {
            $proc = Get-Process -Id $w.Current.ProcessId -ErrorAction SilentlyContinue
            if (-not $proc -or ($proc.Name -ne 'msedge' -and $proc.Name -ne 'chrome')) { continue }
            $btn = Test-Window $w
            if ($btn) {
                ($btn.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)).Invoke()
                Log ("Auto-clicked Allow (pid {0})" -f $proc.Id)
                $clicked = $true
            }
        }
    } catch { }
    return $clicked
}

Log "Watching for '$dlgName' ... (v3 event-driven, log: $logFile)"

# 启动时先扫一次（处理脚本启动前就已弹出的弹窗）
if (Scan-AndClick) { Start-Sleep -Milliseconds 1500 }

# 事件驱动：注册顶层窗口结构变化监听（新窗口/弹窗出现时触发）
$script:pending = $false
$handler = {
    param($source, $e)
    $script:pending = $true
}
[Windows.Automation.Automation]::AddStructureChangedEventHandler(
    $root, [Windows.Automation.TreeScope]::Children, $handler)

# UIA 事件在后台线程投递；PS 5.1 下脚本块从线程池线程回调不可靠（实测未触发），
# 因此保留事件注册（部分环境可用），但主要依赖短周期兜底扫描
$lastSweep = Get-Date
while ($true) {
    Start-Sleep -Milliseconds 200
    if ($script:pending) {
        $script:pending = $false
        if (Scan-AndClick) { Start-Sleep -Milliseconds 1500 }
        $lastSweep = Get-Date
        continue
    }
    # 兜底扫描：每 10s 一次（单次 chrome-UI 扫描 ~58ms CPU，折合 ~0.6% 均值），
    # 保证最坏延迟 ~10s，落在 pi-browser-harness discovery 的 30s 探测窗口内
    if (((Get-Date) - $lastSweep).TotalSeconds -ge 10) {
        if (Scan-AndClick) { Start-Sleep -Milliseconds 1500 }
        $lastSweep = Get-Date
    }
}

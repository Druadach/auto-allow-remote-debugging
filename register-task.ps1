# register-task.ps1 — 一键注册/卸载 auto-allow-remote-debugging 的计划任务
# 用法（在仓库目录内或任意位置执行均可）:
#   powershell -ExecutionPolicy Bypass -File .\register-task.ps1             # 注册并立即启动
#   powershell -ExecutionPolicy Bypass -File .\register-task.ps1 -Unregister # 卸载任务
#
# 与 README 手工片段的关键区别：脚本路径由 $PSScriptRoot 自动拼出，
# 永远指向本文件旁边的真实脚本 —— 不存在把占位符路径照抄进计划任务的坑。
# （坑长这样：任务指向 C:\path\to\... 这种不存在的脚本时，一启动就以
#   0xFFFD0000 退出，任务看似注册成功、实则从未运行。）

[CmdletBinding()]
param(
    [string]$TaskName = 'pi-auto-allow-remote-debugging',
    [switch]$Unregister
)

$self = Join-Path $PSScriptRoot 'auto-allow-remote-debugging.ps1'

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "[OK] 已卸载计划任务 '$TaskName'"
    } else {
        Write-Warning "不存在名为 '$TaskName' 的计划任务"
    }
    exit 0
}

if (-not (Test-Path $self)) {
    Write-Error "未找到 watcher 脚本（应位于本文件旁边）: $self"
    exit 1
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $self + '"')
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
# 心跳兜底：每 30 分钟重复触发一次（实例已在跑时被 IgnoreNew + 脚本内互斥锁挡下，无副作用）。
# 实测 Win11 24H2 下 watcher 进程可能意外终止，而登录触发器要等下次登录才会再拉起 ——
# 期间弹窗无人点。心跳保证最坏 30 分钟内自动复活。
# 注：LogonTrigger 的 CIM 对象不暴露 Repetition 属性，只能用并存的 -Once 重复触发器实现；
#     RepetitionDuration 不能用 [TimeSpan]::MaxValue —— 序列化出的 P99999999DT23H59M59S 超出
#     任务计划程序的合法范围，只能给个足够长的有限值（10 年）。
$heartbeat = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Days 3650)

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -Hidden -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

# 关键：New-ScheduledTaskSettingsSet 默认 IdleSettings.StopOnIdleEnd=True —— 机器进入
# 空闲状态（约 10 分钟无输入）就会终止任务，守护进程"挂一整夜"的经典死法，且命令行
# 没有对应开关，只能改 CIM 对象属性。Win10 注册的旧任务同样带着这个默认值。
$settings.IdleSettings.StopOnIdleEnd = $false

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($trigger, $heartbeat) -Settings $settings -Force | Out-Null

Write-Host "[OK] 已注册计划任务 '$TaskName'"
Write-Host "     watcher 脚本: $self"

# 立即启动一次。若已有实例在跑，watcher 自身的互斥锁会让新实例静默退出，无副作用。
Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '状态:'
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State | Format-List
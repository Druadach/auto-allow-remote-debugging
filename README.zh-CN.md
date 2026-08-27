# auto-allow-remote-debugging

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-blue)](README.zh-CN.md)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)](README.zh-CN.md)

[English](README.md) | 简体中文

> 后台守护脚本：自动点击 Edge / Chrome 的 **"Allow remote debugging?"** 授权弹窗，让 CDP 自动化工具（pi-browser-harness、Playwright connect over CDP、Puppeteer 等）重连时不再被弹窗卡住。

## 快速开始

### 手动运行

```powershell
powershell -ExecutionPolicy Bypass -File .\auto-allow-remote-debugging.ps1
```

弹窗出现后几秒内会被自动点掉。日志写在 `%TEMP%\pi-auto-allow.log`。

### 开机自启（任务计划程序）

**推荐：一行安装。** 任务路径由 `$PSScriptRoot`（`register-task.ps1` 所在目录）自动拼接，
无需手改占位符 —— 原因见下方警告：

```powershell
powershell -ExecutionPolicy Bypass -File .\register-task.ps1              # 注册并立即启动
powershell -ExecutionPolicy Bypass -File .\register-task.ps1 -Unregister  # 卸载任务
```

管理：

```powershell
Get-ScheduledTask  -TaskName 'pi-auto-allow-remote-debugging'   # 查状态
Start-ScheduledTask  -TaskName 'pi-auto-allow-remote-debugging' # 启动
Stop-ScheduledTask   -TaskName 'pi-auto-allow-remote-debugging' # 停止
Unregister-ScheduledTask -TaskName 'pi-auto-allow-remote-debugging' -Confirm:$false  # 卸载
```

> ⚠️ **手工抄下面这段之前，务必把路径改掉。** 示例里的 `C:\path\to\...` 是占位符。
> 任务指向不存在的脚本时，一启动就会以结果码 `0xFFFD0000`（PowerShell 的
> "`-File` 参数不存在"）退出，任务看似注册成功、实则从未运行 —— 这正是
> `register-task.ps1` 存在的原因。

以当前用户身份手工注册（无需管理员）—— **请先修改路径**：

```powershell
$script   = 'C:\path\to\auto-allow-remote-debugging.ps1'  # ← 改成你的真实路径
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"')
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -Hidden -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
Register-ScheduledTask -TaskName 'pi-auto-allow-remote-debugging' `
  -Action $action -Trigger $trigger -Settings $settings -Force
```

### 验证是否生效

```bash
node test/probe.mjs
```

探针会向 DevTools 端口发起新的 CDP 连接（自动读取 `DevToolsActivePort` 文件），触发弹窗。若 watcher 正常工作，几秒内打印 `✓ SUCCESS`；若 20s 超时说明弹窗没被点掉。

## 背景

Chromium 系浏览器（实测 Edge 151）对**每一条新的外部 CDP 连接**都会弹原生授权框 —— 不是授权一次终身有效。未授权时：

- HTTP 发现端点 `http://127.0.0.1:<port>/json/version` 返回 **404**
- WebSocket 握手挂起，直到人工点 Allow

自动化工具（如 [pi-browser-harness](https://github.com/anthropics/pi-browser-harness) 的 daemon 重连）会被卡在弹窗上直至超时。

**为什么不能常规自动化？** 弹窗是浏览器原生 UI，不在任何网页 DOM 里，页面级工具够不着；而且它授予的正是 CDP 调试权限 —— 自动化点击本身需要先有这个权限（鸡生蛋问题）。组策略 `RemoteDebuggingAllowed` 只能整体开/关远程调试，没有"自动同意"开关。

唯一可行的自动化层级是 **OS 级 UI 自动化（UIA）**，这就是本脚本。

## 工作原理

```
┌─ PowerShell 常驻进程（隐藏窗口，~75 MB 内存）──────────────┐
│  1. 每 10s 扫一遍顶层浏览器窗口（Chrome_WidgetWin_1）        │
│  2. 只遍历 chrome UI 子树，跳过 Chrome_RenderWidgetHostHWND │
│     （渲染器内容子树 —— 这是低 CPU 的关键）                  │
│  3. 三重条件确认：                                           │
│     ✓ 窗口内存在 "Allow remote debugging?" 文本             │
│     ✓ 存在名为 "Allow" 的 Button 控件                       │
│     ✓ 进程名为 msedge / chrome                              │
│  4. InvokePattern.Invoke() 点击 Allow，1.5s 冷却防重复       │
└──────────────────────────────────────────────────────────┘
```

## 性能（实测）

| 版本 | 机制 | watcher CPU | 浏览器连带 CPU | 响应延迟 |
|---|---|---|---|---|
| v1 全树轮询 | 500ms 遍历整棵 UIA 树 | ~17% | **~47%** ⚠️ | ≤0.5s |
| v2 跳过渲染器子树 | 500ms 只扫 chrome UI | ~11.6% | ~7% | ≤0.5s |
| **v3（现行）** | 结构变化事件 + 10s 兜底扫描 | **~0.6% 均值** | ~0 | 典型 ~2s，最坏 ~10s |

> ⚠️ v1 的全树遍历会强迫 Chromium 为所有标签页维护完整无障碍树，浏览器侧 CPU 飙到 47% —— **不要对 Chromium 窗口做全树 UIA 轮询**，这是本仓库最大的实测教训。
>
> 另：PS 5.1 下 UIA 事件回调（脚本块从线程池线程投递）实测不可靠，点击实际都是兜底扫描逮到的。所以 v3 保留了 10s 兜底扫描作为主要捕获路径。
## 已知坑（Windows PowerShell 5.1）

1. **含非 ASCII 字符的 .ps1 必须是 UTF-8 with BOM**，否则按 GBK 误读产生幻影解析错误（本仓库文件已带 BOM）。
2. `New-Object X(...)` 多层嵌套括号参数会报 `Unexpected token ')'`，拍平成独立变量即可。
3. 结构变化事件必须用 `AddStructureChangedEventHandler`（`AddAutomationEventHandler` 传 `StructureChangedEvent` 会报 "eventId not valid"）。
4. 按命令行模式查/杀进程时，**查询进程自身会被匹配**（`-Command` 字符串里含模式文本），务必排除 `$PID`。

## 替代方案对比

| 方案 | 优点 | 缺点 |
|---|---|---|
| **本脚本（UIA 守护）** | 保留日常 Profile 登录态；全自动 | 常驻进程 ~75MB；本质是把安全确认自动化，有风险（见下） |
| 启动参数 `--remote-debugging-port=9222 --user-data-dir=...` | 零弹窗、零常驻 | 新版 Chromium 在默认用户数据目录上**忽略**该参数，必须用独立目录 → 无日常登录态 |
| 手动点一次 | 最安全 | Edge 151 对每条新 CDP 连接都重弹，重启后就要再点 |
| 组策略 `RemoteDebuggingAllowed` | 官方 | 只能整体禁用，没有"自动同意" |

## ⚠️ 安全提示

运行本脚本 = 把浏览器的远程调试确认自动化掉了。**任何能以你的用户身份执行代码的程序，都可以借它静默取得浏览器的完全控制权**（包括全部已登录站点的 Cookie）。请仅在你能接受该风险的机器上使用。

## License

[MIT](LICENSE)

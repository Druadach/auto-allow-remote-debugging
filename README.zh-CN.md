# auto-allow-remote-debugging

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-blue)](README.zh-CN.md)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)](README.zh-CN.md)

[English](README.md) | 简体中文

> 后台守护脚本：自动点击 Edge / Chrome 的 **"Allow remote debugging?"** 授权弹窗，让 CDP 自动化工具（pi-browser-harness、Playwright connect over CDP、Puppeteer 等）重连时不再被弹窗卡住。

> 本项目的开发得到 [LINUX DO 社区](https://linux.do) 的支持与认可。

同时支持 **en-US** 与 **zh-CN** 两种浏览器界面（`-Texts en|zh|both`，默认 `both`）。

## 快速开始

### 手动运行

```powershell
powershell -ExecutionPolicy Bypass -File .\auto-allow-remote-debugging.ps1
```

弹窗出现后约 1 秒内被点掉 —— 实测从窗口事件到点击 777~906 ms。日志写在 `%TEMP%\pi-auto-allow.log`。

常用参数：

```powershell
# 只记录"会点哪个按钮"，不真的点
powershell -ExecutionPolicy Bypass -File .\auto-allow-remote-debugging.ps1 -DryRun -MaxSeconds 120

# 打印浏览器 chrome UI 的控件树 —— 真实本地化文案就是这么挖出来的
powershell -ExecutionPolicy Bypass -File .\auto-allow-remote-debugging.ps1 -Probe -MaxSeconds 60

# 只用其中一种语言的内置名称表
powershell -ExecutionPolicy Bypass -File .\auto-allow-remote-debugging.ps1 -Texts zh
```

`-MaxSeconds 0`（默认）表示一直运行到 Ctrl+C。

### 开机自启（任务计划程序）

**推荐：一行安装。** 任务路径由 `$PSScriptRoot`（`register-task.ps1` 所在目录）自动拼接，
无需手改占位符 —— 原因见下方警告：

```powershell
powershell -ExecutionPolicy Bypass -File .\register-task.ps1              # 注册并立即启动
powershell -ExecutionPolicy Bypass -File .\register-task.ps1 -Unregister  # 卸载任务
```

`register-task.ps1` 不传任何额外参数，因此脚本默认值（`-Texts both`、30 秒兜底）直接生效。管理：

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

> watcher 必须跑在登录用户的**交互式会话**里。在服务上下文或 SSH 会话（Windows session 0）中，
> UIA 根节点下的浏览器窗口数是 **0** —— 那样的 watcher 只是干坐着什么也看不到。
> 所以"注册成登录用户的任务"才是受支持的用法。

### 验证是否生效

```bash
node test/probe.mjs
```

探针会向 DevTools 端口发起新的 CDP 连接（自动读取 `DevToolsActivePort` 文件），触发弹窗。若 watcher 正常工作，几秒内打印 `✓ SUCCESS`；若 20s 超时说明弹窗没被点掉。

若探针找不到端口，注意浏览器**并不总会**写 `DevToolsActivePort` 文件 —— 全新 profile 配显式
`--remote-debugging-port` 时，端口在听但那个文件始终不出现。直接问浏览器：

```powershell
(Invoke-WebRequest http://127.0.0.1:9222/json/version -UseBasicParsing).Content
```

## 背景

Chromium 系浏览器（实测 Edge 151 **与 Edge 155**）对**每一条新的外部 CDP 连接**都会弹原生授权框 —— 不是授权一次终身有效。未授权时：

- HTTP 发现端点 `http://127.0.0.1:<port>/json/version` 返回 **404**
- WebSocket 握手挂起，直到人工点 Allow

自动化工具（如 [pi-browser-harness](https://github.com/anthropics/pi-browser-harness) 的 daemon 重连）会被卡在弹窗上直至超时。

**为什么不能常规自动化？** 弹窗是浏览器原生 UI，不在任何网页 DOM 里，页面级工具够不着；而且它授予的正是 CDP 调试权限 —— 自动化点击本身需要先有这个权限（鸡生蛋问题）。组策略 `RemoteDebuggingAllowed` 只能整体开/关远程调试，没有"自动同意"开关。

唯一可行的自动化层级是 **OS 级 UI 自动化（UIA）**，这就是本脚本。

什么情况下才会弹框？Edge 155 实测：**全新 profile 配显式 `--remote-debugging-port`** 会被当作已显式授权 —— CDP 直接连上、根本不弹框。而**"记住过远程调试"的 profile**（命令行没有该参数，但 `DevToolsActivePort` 存在、端口在听）会弹框，且弹框会**挡住连接**直到被点。所以"握手挂起"还是"握手秒回"本身就是"有没有待授权弹窗"的可靠判据 —— 不需要截图。

## 工作原理

```
┌─ PowerShell 常驻进程（隐藏窗口，~75 MB 内存）──────────────┐
│  1. SetWinEventHook 监听 EVENT_OBJECT_CREATE 与             │
│     EVENT_OBJECT_SHOW(0x8002)，按 hwnd 反查 pid 只认         │
│     msedge/chrome —— 回调与消息泵都在 C# 里，不在 PS 脚本块  │
│  2. 命中事件后扫这个窗口；首扫未命中则 400ms 后再扫一次      │
│     （窗口往往先于它的 UIA 子元素存在）                      │
│  3. 扫描遍历浏览器 chrome UI，本意是跳过渲染器内容子树       │
│     —— 见下方"已知限制"                                      │
│  4. 点击前三重条件确认：                                     │
│     ✓ 窗口内存在 "Allow remote debugging?" /                │
│       "是否允许远程调试?" 文本                               │
│     ✓ 存在名为 "Allow" / "允许" 的 Button 控件               │
│     ✓ 窗口进程是 msedge / chrome                             │
│  5. InvokePattern.Invoke() 点击该按钮                        │
│  6. 仍然保留 30s 兜底扫描，所以丢一次事件不会再等于          │
│     "这个弹窗永远没人点"                                     │
└──────────────────────────────────────────────────────────────┘
```

为什么既用事件又留兜底扫描：上一版依赖 UIA 结构变化事件，而 PS 5.1 下这类回调（脚本块从
线程池线程投递）实测不可靠 —— 点击实际都是兜底扫描逮到的。本版把
hook → 回调 → 消息泵整条链路下沉到 C#，从构造上消除该失效模式；同时仍然保留（更慢的）兜底扫描，
因为彻底删掉兜底会让一次丢事件变成永久不点。

## 性能（实测）

| 版本 | 机制 | watcher CPU | 浏览器连带 CPU | 响应延迟 |
|---|---|---|---|---|
| v1 全树轮询 | 500ms 遍历整棵 UIA 树 | ~17% | **~47%** ⚠️ | ≤0.5s |
| v2 跳过渲染器子树 | 500ms 只扫 chrome UI | ~11.6% | ~7% | ≤0.5s |
| v3 | 结构变化事件 + 10s 兜底扫描 | ~0.6% 均值 | ~0 | 典型 ~2s，最坏 ~10s |
| **v5（现行）** | WinEventHook（C# 回调）+ 400ms 重扫，30s 兜底扫描 | 两次扫描之间 ~0%（空闲时阻塞在消息队列） | 见下方"已知限制" | **实测 777~906 ms** |

> ⚠️ v1 的全树遍历会强迫 Chromium 为所有标签页维护完整无障碍树，浏览器侧 CPU 飙到 47% —— **不要对 Chromium 窗口做全树 UIA 轮询**，这是本仓库最大的实测教训。
>
> 另：PS 5.1 下用 PowerShell 脚本块注册的 UIA/WinEvent 回调（从线程池线程投递）实测不可靠 —— 点击实际都是兜底扫描逮到的。所以本版把回调链放在 C# 里（静态委托 + 静态字段），并保留兜底扫描作为第二条路径。

## ⚠️ 已知限制：渲染器子树剪枝在 Edge 155 上已失效

扫描本意是靠类名 `Chrome_RenderWidgetHostHWND` 跳过网页内容。但 Edge 155 上这个类名**不再
出现在 `Chrome_WidgetWin_1` 的直接子节点上** —— 直接子节点现在是 `Intermediate D3D Window`
和 `BrowserRootView` —— 于是"这不是渲染器子树吗？"这个判断**恒为真**，扫描实际上仍会伸进
网页内容（`ControlType.Document`）。

后果：

- 每次扫描都可能遍历已打开标签页的 DOM，所以 30s 兜底扫描并不像设计的那样便宜
  （开销回到 v2 量级，不是 v1 量级）；
- 理论上，如果某个网页同时存在与对话框标题完全同名的 Text 和名为 `Allow` / `允许` 的
  Button，点击就可能落到网页元素而不是弹窗上。

v2、v3 用的是同一个剪枝，所以这是**继承下来的**，不是本版引入的回归。修法是：改用显式
`ControlViewWalker` 遍历，在 `ControlType.Document` 处剪掉整棵子树 —— 该判据不依赖类名，跨
Chromium 版本稳定 —— 但必须对真实弹窗验证过后才能合入。在那之前，本文档里关于"跳过渲染器
子树"的说法请当作**设计意图**，而不是实测行为。

## 本地化文案

本地化文案取自浏览器自己的语言包（`zh-CN.pak` 资源表，含 alias 表），不是猜的：

| 元素 | 资源 ID | en-US | zh-CN |
|---|---|---|---|
| 对话框标题 | 12900 | `Allow remote debugging?` | `是否允许远程调试?` |
| 肯定按钮 | 12905 → alias → **7844** | `Allow` | `允许` |
| 否定按钮 | 12906 | `Deny` | `拒绝` |

已在真实弹窗上确认（`CLICKED 'Allow' dialog='Allow remote debugging?'` 与
`CLICKED '允许' dialog='是否允许远程调试?'`）。注意肯定按钮的名字**不在**它自己的 ID 下 ——
12905 是一条 alias，解析后指向资源 7844，这正是"按 ID 扫表找不到 Allow"的原因。

其他语言可以用 `-DialogTexts` / `-ButtonTexts` 整体覆盖内置表；准确的文案从 `-Probe` 拿 ——
它会把 chrome UI 的控件树打出来。

## 参数

| 参数 | 默认值 | 作用 |
|---|---|---|
| `-Texts` | `both` | 启用哪套内置名称表：`en`、`zh` 或 `both` |
| `-DialogTexts` | — | 整体替换对话框标题的匹配列表 |
| `-ButtonTexts` | — | 整体替换按钮名的匹配列表 |
| `-FallbackSeconds` | `30` | 兜底扫描间隔（`0` = 关闭，不建议） |
| `-MinScanIntervalMs` | `200` | 两次扫描的最小间隔（合并突发事件） |
| `-RetryAfterMs` | `400` | 首扫未命中后多久重扫（`0` = 不重试） |
| `-MaxSeconds` | `0` | 跑满 N 秒后退出（`0` = 一直跑到 Ctrl+C） |
| `-DryRun` | 关 | 只记录"会点哪个"，不真的点 |
| `-Probe` | 关 | 把 chrome UI 的控件树写进日志 |
| `-LogFile` | `%TEMP%\pi-auto-allow.log` | 日志路径 |
| `-MutexName` | `Global\pi-auto-allow-remote-debugging` | 单实例互斥体名 |

## 已知坑（Windows PowerShell 5.1 / Win11）

1. **含非 ASCII 字符的 .ps1 必须是 UTF-8 with BOM**，否则按 GBK 误读产生幻影解析错误（本仓库文件已带 BOM）。
2. `New-Object X(...)` 多层嵌套括号参数会报 `Unexpected token ')'`，拍平成独立变量即可。
3. 结构变化事件必须用 `AddStructureChangedEventHandler`（`AddAutomationEventHandler` 传 `StructureChangedEvent` 会报 "eventId not valid"）。
4. 按命令行模式查/杀进程时，**查询进程自身会被匹配**（`-Command` 字符串里含模式文本），务必排除 `$PID`。
5. **Win10→Win11 升级后的"静止死亡"**：`New-ScheduledTaskSettingsSet` 默认 `IdleSettings.StopOnIdleEnd=true`，机器进入空闲（约 10 分钟无输入）即终止任务；watcher 被杀后，登录触发器要等**下次登录**才会拉起 —— 期间弹窗无人点，现象与"升级后脚本失效"一模一样。`register-task.ps1` 已显式关闭该开关，并加 30 分钟心跳触发器 + 失败自动重启兜底；升级系统后重新执行一次 `register-task.ps1` 即可。另注意：心跳的 `RepetitionDuration` 不能用 `[TimeSpan]::MaxValue`（序列化成 P99999999DT23H59M59S 超范围导致注册失败），要用有限的足够长时长。
6. **Win11 默认终端是 Windows Terminal，会无视 `-WindowStyle Hidden`**：计划任务每次拉起 watcher 都会在 WT 里弹出可见控制台窗口，心跳触发时还会反复弹。`register-task.ps1` 已改用 `conhost.exe --headless powershell.exe ...` 包装启动 —— 强制用无头 conhost 托管控制台，绕过 WT 的 console handoff，窗口完全不出现；默认终端仍为传统 conhost 的系统（如 Win10）不受影响。
7. **不要把 WinEvent / UIA 回调注册成 PowerShell 脚本块。** PS 5.1 下由线程池线程投递的脚本块委托**静默不触发** —— hook 看起来装上了、日志却一直是空的，表现得像"弹窗从没出现过"。把委托和它要读的状态放进 C#（静态委托 + 静态字段），PowerShell 里只留消息泵。
8. **watcher 必须跑在交互式会话里。** 在 session 0（服务、或 SSH 会话）下 `AutomationElement.RootElement.Children` 里**一个**浏览器窗口都没有 —— UIA 看不见另一个会话的窗口。所以"它在那种上下文里枚举到 0 个窗口"这类观察毫无意义。
9. **浏览器并不总会写 `DevToolsActivePort`**：全新 profile 配显式 `--remote-debugging-port` 时，端口在听却从不生成该文件。判活要探端口 / `/json/version`，不要等这个文件。
10. **从 `C:\Windows\Temp` 启动 `.ps1` 的任务 action 会失败**（任务结果 `0x1`，`-File` 形式则是 `0xFFFD0000`），尽管同一条命令交互式执行完全正常 —— 把脚本放在 `register-task.ps1` 旁边，或把内容以 base64 内联进 action（`-EncodedCommand`）。

## 替代方案对比

| 方案 | 优点 | 缺点 |
|---|---|---|
| **本脚本（UIA 守护）** | 保留日常 Profile 登录态；全自动 | 常驻进程 ~75MB；本质是把安全确认自动化，有风险（见下） |
| 启动参数 `--remote-debugging-port=9222 --user-data-dir=...` | 零弹窗、零常驻 | 新版 Chromium 在默认用户数据目录上**忽略**该参数，必须用独立目录 → 无日常登录态 |
| 手动点一次 | 最安全 | Edge 151/155 对每条新 CDP 连接都重弹，重启后就要再点 |
| 组策略 `RemoteDebuggingAllowed` | 官方 | 只能整体禁用，没有"自动同意" |

## ⚠️ 安全提示

运行本脚本 = 把浏览器的远程调试确认自动化掉了。**任何能以你的用户身份执行代码的程序，都可以借它静默取得浏览器的完全控制权**（包括全部已登录站点的 Cookie）。请仅在你能接受该风险的机器上使用。

有两件事让这个风险比字面上更锋利。第一，由于上方那条已知限制，扫描目前会伸进网页内容 ——
所以原则上恶意网页可以尝试伪造匹配的控件来让自己被点，尽管点击目标始终被解析为
"进程是 `msedge`/`chrome` 的窗口内、名字精确等于 `Allow` / `允许` 的 `Button` 控件"。
第二，本脚本是**替你**回答授权弹窗且不通知你，所以有新连接被授权时你不会察觉。

## License

[MIT](LICENSE)

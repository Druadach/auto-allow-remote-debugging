# auto-allow-remote-debugging

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-blue)](README.md)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)](README.md)

English | [简体中文](README.zh-CN.md)

> A background watcher that auto-clicks Edge / Chrome's native **"Allow remote debugging?"** consent dialog, so CDP automation tools (pi-browser-harness, Playwright connect-over-CDP, Puppeteer, etc.) can reconnect without getting stuck on the prompt.

> This project's development was supported by and is acknowledged in the [LINUX DO community](https://linux.do).

## Quick start

### Run manually

```powershell
powershell -ExecutionPolicy Bypass -File .\auto-allow-remote-debugging.ps1
```

Dialogs get auto-clicked within seconds. Log: `%TEMP%\pi-auto-allow.log`.

### Autostart at logon (Task Scheduler)

**Recommended — one-command installer.** The task path is derived from `$PSScriptRoot`
(the folder containing `register-task.ps1`), so there is no placeholder path to edit —
see the warning below for why that matters:

```powershell
powershell -ExecutionPolicy Bypass -File .\register-task.ps1             # register + start now
powershell -ExecutionPolicy Bypass -File .\register-task.ps1 -Unregister # remove the task
```

Manage it:

```powershell
Get-ScheduledTask  -TaskName 'pi-auto-allow-remote-debugging'   # status
Start-ScheduledTask  -TaskName 'pi-auto-allow-remote-debugging' # start
Stop-ScheduledTask   -TaskName 'pi-auto-allow-remote-debugging' # stop
Unregister-ScheduledTask -TaskName 'pi-auto-allow-remote-debugging' -Confirm:$false  # remove
```

> ⚠️ **Fix the path before copying the manual snippet below.** It contains the
> placeholder `C:\path\to\...`. A task whose action points at a non-existent script
> exits the moment it starts with task result `0xFFFD0000` (PowerShell's
> "the -File argument does not exist") and silently never runs — exactly why
> `register-task.ps1` exists.

Manual registration as the current user (no admin required) — **edit the path**:

```powershell
$script   = 'C:\path\to\auto-allow-remote-debugging.ps1'  # <- EDIT THIS
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"')
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -Hidden -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
Register-ScheduledTask -TaskName 'pi-auto-allow-remote-debugging' `
  -Action $action -Trigger $trigger -Settings $settings -Force
```

### Verify it works

```bash
node test/probe.mjs
```

The probe opens a fresh CDP connection to the DevTools port (auto-discovered from the `DevToolsActivePort` file), which triggers the dialog. If the watcher is working you'll see `✓ SUCCESS` within seconds; a 20s timeout means the dialog wasn't clicked.

## Background

Chromium browsers (verified on Edge 151) pop the native consent dialog for **every new external CDP connection** — it is not a one-time grant. While unauthorized:

- the HTTP discovery endpoint `http://127.0.0.1:<port>/json/version` returns **404**
- the WebSocket handshake hangs until a human clicks Allow

Automation tools (e.g. [pi-browser-harness](https://github.com/anthropics/pi-browser-harness) daemon reconnects) block on the dialog until they time out.

**Why can't this be automated normally?** The dialog is native browser UI — it lives outside any page DOM, so page-level tools (`page.click`, CDP input events into pages) can't reach it. And it grants the very CDP debugging permission that automation would need to click it — a chicken-and-egg problem. The group policy `RemoteDebuggingAllowed` can only enable/disable remote debugging entirely; there is no "auto-consent" switch.

The only workable automation layer is **OS-level UI Automation (UIA)** — which is exactly what this script does.

## How it works

```
┌─ Resident PowerShell process (hidden window, ~75 MB RAM) ────┐
│  1. Every 10s, scan top-level browser windows                │
│     (Chrome_WidgetWin_1)                                     │
│  2. Walk ONLY the browser chrome UI subtree, skipping        │
│     Chrome_RenderWidgetHostHWND (renderer content subtree    │
│     — this is the key to low CPU)                            │
│  3. Triple condition before clicking:                        │
│     ✓ window contains "Allow remote debugging?" text         │
│     ✓ a Button control named "Allow" exists                  │
│     ✓ process name is msedge / chrome                        │
│  4. InvokePattern.Invoke() on Allow, 1.5s cooldown to        │
│     avoid double-fire                                        │
└──────────────────────────────────────────────────────────────┘
```

## Performance (measured)

| Version | Mechanism | Watcher CPU | Browser-side CPU | Reaction time |
|---|---|---|---|---|
| v1 full-tree polling | 500ms walks of the entire UIA tree | ~17% | **~47%** ⚠️ | ≤0.5s |
| v2 chrome-UI-only polling | 500ms, renderer subtree skipped | ~11.6% | ~7% | ≤0.5s |
| **v3 (current)** | structure-changed events + 10s fallback sweep | **~0.6% avg** | ~0 | typically ~2s, worst ~10s |

> ⚠️ v1's full-tree walks force Chromium to build/marshal complete accessibility trees for every open tab — browser-side CPU spiked to 47%. **Never poll Chromium windows with full-tree UIA queries**; this is the biggest measured lesson in this repo.
>
> Also: on Windows PowerShell 5.1, UIA event callbacks (scriptblocks invoked from threadpool threads) proved unreliable in testing — clicks were actually caught by the fallback sweep. v3 therefore keeps a 10s sweep as the primary catch path.
## Known pitfalls (Windows PowerShell 5.1 / Win11)

1. **.ps1 files with non-ASCII characters must be UTF-8 with BOM**, otherwise PS 5.1 misreads them as ANSI/GBK and produces phantom parse errors (this repo's script ships with BOM).
2. Multi-level nested `New-Object X(...)` parentheses fail with `Unexpected token ')'` — flatten into separate variables.
3. Structure-changed events require `AddStructureChangedEventHandler` (`AddAutomationEventHandler` with `StructureChangedEvent` throws "eventId not valid").
4. When querying/killing processes by command-line pattern, **the querying process matches itself** (its `-Command` string contains the pattern) — always exclude `$PID`.
5. **Silent death after Win10→Win11 upgrade**: `New-ScheduledTaskSettingsSet` defaults to `IdleSettings.StopOnIdleEnd=true` — the task gets terminated once the machine goes idle (~10 min without input). Once the watcher dies, the logon trigger won't fire again until the **next logon**, so popups go unanswered — looks exactly like "the script broke after the upgrade". `register-task.ps1` now disables that switch explicitly and adds a 30-min heartbeat trigger + restart-on-failure as a safety net; after an OS upgrade, just re-run `register-task.ps1` once. Also note: the heartbeat's `RepetitionDuration` must not be `[TimeSpan]::MaxValue` (it serializes to P99999999DT23H59M59S, which the Task Scheduler rejects as out of range) — use a finite, long-enough duration instead.

## Alternatives compared

| Approach | Pros | Cons |
|---|---|---|
| **This script (UIA watcher)** | Keeps daily-profile logins; fully automatic | Resident process ~75MB; automates away a security confirmation (see below) |
| Launch flags `--remote-debugging-port=9222 --user-data-dir=...` | No dialog, no resident process | Recent Chromium **ignores** the flag on the default user-data dir — needs a separate dir → no daily logins |
| Click once manually | Safest | Edge 151 re-prompts for every new CDP connection; every browser restart means another click |
| Group policy `RemoteDebuggingAllowed` | Official | Can only disable remote debugging entirely; no "auto-consent" |

## ⚠️ Security notice

Running this script automates away the browser's remote-debugging consent. **Any program that can execute code as your user can silently gain full control of the browser** (including cookies of every logged-in site). Use only on machines where you accept that risk.

## License

[MIT](LICENSE)

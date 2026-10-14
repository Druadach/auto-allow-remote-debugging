# auto-allow-remote-debugging

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-blue)](README.md)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)](README.md)

English | [简体中文](README.zh-CN.md)

> A background watcher that auto-clicks Edge / Chrome's native **"Allow remote debugging?"** consent dialog, so CDP automation tools (pi-browser-harness, Playwright connect-over-CDP, Puppeteer, etc.) can reconnect without getting stuck on the prompt.

> This project's development was supported by and is acknowledged in the [LINUX DO community](https://linux.do).

Handles both **en-US** and **zh-CN** browser UI (`-Texts en|zh|both`, default `both`).

## Quick start

### Run manually

```powershell
powershell -ExecutionPolicy Bypass -File .\auto-allow-remote-debugging.ps1
```

The dialog is clicked about a second after it appears — measured 777–906 ms from window event to click. Log: `%TEMP%\pi-auto-allow.log`.

Useful flags:

```powershell
# report which button WOULD be clicked, without clicking anything
powershell -ExecutionPolicy Bypass -File .\auto-allow-remote-debugging.ps1 -DryRun -MaxSeconds 120

# dump the browser chrome control tree — this is how the real localized strings were found
powershell -ExecutionPolicy Bypass -File .\auto-allow-remote-debugging.ps1 -Probe -MaxSeconds 60

# restrict the built-in name table to a single locale
powershell -ExecutionPolicy Bypass -File .\auto-allow-remote-debugging.ps1 -Texts zh
```

`-MaxSeconds 0` (the default) means "run until Ctrl+C".

### Autostart at logon (Task Scheduler)

**Recommended — one-command installer.** The task path is derived from `$PSScriptRoot`
(the folder containing `register-task.ps1`), so there is no placeholder path to edit —
see the warning below for why that matters:

```powershell
powershell -ExecutionPolicy Bypass -File .\register-task.ps1             # register + start now
powershell -ExecutionPolicy Bypass -File .\register-task.ps1 -Unregister # remove the task
```

`register-task.ps1` passes no extra arguments, so the script's defaults (`-Texts both`,
30s fallback) apply. Manage the task:

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

> The watcher must run **in the interactive session** of the logged-on user. From a
> service context or an SSH session (Windows session 0) the UIA root has **zero**
> browser windows, so the watcher would sit there watching nothing — a task registered
> for the logged-on user is the supported arrangement.

### Verify it works

```bash
node test/probe.mjs
```

The probe opens a fresh CDP connection to the DevTools port (auto-discovered from the `DevToolsActivePort` file), which triggers the dialog. If the watcher is working you'll see `✓ SUCCESS` within seconds; a 20s timeout means the dialog wasn't clicked.

If the probe can't find the port, note that the browser does **not always** write the
`DevToolsActivePort` file — with a fresh profile and an explicit
`--remote-debugging-port`, the port listens but the file never appears. Ask the browser
directly instead:

```powershell
(Invoke-WebRequest http://127.0.0.1:9222/json/version -UseBasicParsing).Content
```

## Background

Chromium browsers (verified on Edge 151 **and Edge 155**) pop the native consent dialog for **every new external CDP connection** — it is not a one-time grant. While unauthorized:

- the HTTP discovery endpoint `http://127.0.0.1:<port>/json/version` returns **404**
- the WebSocket handshake hangs until a human clicks Allow

Automation tools (e.g. [pi-browser-harness](https://github.com/anthropics/pi-browser-harness) daemon reconnects) block on the dialog until they time out.

**Why can't this be automated normally?** The dialog is native browser UI — it lives outside any page DOM, so page-level tools (`page.click`, CDP input events into pages) can't reach it. And it grants the very CDP debugging permission that automation would need to click it — a chicken-and-egg problem. The group policy `RemoteDebuggingAllowed` can only enable/disable remote debugging entirely; there is no "auto-consent" switch.

The only workable automation layer is **OS-level UI Automation (UIA)** — which is exactly what this script does.

When does the dialog even appear? Measured on Edge 155: a **fresh profile launched with an explicit `--remote-debugging-port`** is treated as already-consented — CDP connects immediately and no dialog appears. A profile that has **remembered remote debugging** (no flag on the command line, but `DevToolsActivePort` present and the port listening) does prompt, and the prompt blocks the connection until it is answered. "The handshake hangs" versus "the handshake answers" is therefore a reliable signal for "there is a pending dialog" — no screenshot required.

## How it works

```
┌─ Resident PowerShell process (hidden window, ~75 MB RAM) ──────┐
│  1. SetWinEventHook for EVENT_OBJECT_CREATE and                │
│     EVENT_OBJECT_SHOW (0x8002), filtered to msedge/chrome      │
│     pids — callback AND message pump live in C#, not in        │
│     PowerShell scriptblocks                                    │
│  2. On a relevant event: scan that window; if the first scan   │
│     finds nothing, scan once more after 400ms (the window      │
│     often exists before its UIA children do)                   │
│  3. The scan walks the browser chrome UI and is meant to skip  │
│     the renderer content subtree — see the known limitation    │
│     below                                                      │
│  4. Triple condition before clicking:                          │
│     ✓ window contains "Allow remote debugging?" /              │
│       "是否允许远程调试?"                                      │
│     ✓ a Button control named "Allow" / "允许" exists           │
│     ✓ the window's process is msedge / chrome                  │
│  5. InvokePattern.Invoke() on that button                      │
│  6. A 30s fallback sweep still runs, so losing one event can   │
│     no longer mean a permanently unanswered dialog             │
└────────────────────────────────────────────────────────────────┘
```

Why events *and* a fallback sweep: the previous revision relied on UIA
structure-changed events, and on Windows PowerShell 5.1 those callbacks (scriptblocks
invoked from threadpool threads) proved unreliable in testing — clicks were actually
caught by the fallback sweep. This revision moves the whole
hook → callback → message-pump chain into C# so that failure mode is designed out, and
keeps a (slower) fallback sweep anyway, because a revision that dropped the sweep
entirely would turn one lost event into a permanently unanswered dialog.

## Performance (measured)

| Version | Mechanism | Watcher CPU | Browser-side CPU | Reaction time |
|---|---|---|---|---|
| v1 full-tree polling | 500ms walks of the entire UIA tree | ~17% | **~47%** ⚠️ | ≤0.5s |
| v2 chrome-UI-only polling | 500ms, renderer subtree skipped | ~11.6% | ~7% | ≤0.5s |
| v3 | structure-changed events + 10s fallback sweep | ~0.6% avg | ~0 | typically ~2s, worst ~10s |
| **v5 (current)** | WinEventHook (C# callback) + 400ms retry, 30s fallback sweep | ~0% between sweeps (idle = blocked on the message queue) | see the known limitation below | **777–906 ms measured** |

> ⚠️ v1's full-tree walks force Chromium to build/marshal complete accessibility trees for every open tab — browser-side CPU spiked to 47%. **Never poll Chromium windows with full-tree UIA queries**; this is the biggest measured lesson in this repo.
>
> Also: on Windows PowerShell 5.1, UIA/WinEvent callbacks registered as PowerShell scriptblocks (invoked from threadpool threads) proved unreliable — clicks were actually caught by the fallback sweep. Hence the callback chain now lives in C# (a static delegate + static state), and the fallback sweep is kept as a second path.

## ⚠️ Known limitation: the renderer-subtree skip no longer holds on Edge 155

The scan is *supposed* to skip page content by looking for `Chrome_RenderWidgetHostHWND`.
On Edge 155 that class no longer appears as a direct child of `Chrome_WidgetWin_1` —
the direct children are now `Intermediate D3D Window` and `BrowserRootView` — so the
"is this not a renderer subtree?" condition is always true and a scan reaches into the
page content (`ControlType.Document`) after all.

Consequences:

- every scan may traverse the DOM of the open tabs, so the 30s fallback sweep is not as
  cheap as intended (the cost is back in v2 territory, not v1);
- in theory, if a page contained both a Text named exactly like the dialog title and a
  Button named `Allow` / `允许`, the click could land on a page element instead of on the dialog.

v2 and v3 use the same skip, so this is inherited, not introduced by this revision.
The fix — walk with an explicit `ControlViewWalker` and prune the entire subtree at
`ControlType.Document`, a criterion that does not depend on a class name — must be
validated against a real dialog before it is merged. Until then, treat the pruning
claims in this README as "intended design", not as measured behaviour.

## Localized dialogs

The localized strings come from the browser's own language pack (`zh-CN.pak` resource
table, including the alias table), not from guesswork:

| Element | Resource ID | en-US | zh-CN |
|---|---|---|---|
| Dialog title | 12900 | `Allow remote debugging?` | `是否允许远程调试?` |
| Affirmative button | 12905 → alias → **7844** | `Allow` | `允许` |
| Negative button | 12906 | `Deny` | `拒绝` |

Confirmed on real dialogs (`CLICKED 'Allow' dialog='Allow remote debugging?'` and
`CLICKED '允许' dialog='是否允许远程调试?'`). Note the button name is not in the
resource table under its own ID — 12905 is an alias that resolves to resource 7844,
which is why it cannot be found by scanning the table by ID.

For another locale, override the built-in tables with `-DialogTexts` / `-ButtonTexts`,
and get the exact strings from `-Probe`, which dumps the chrome UI control tree.

## Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-Texts` | `both` | Which built-in name table to enable: `en`, `zh` or `both` |
| `-DialogTexts` | — | Replace the dialog-title match list entirely |
| `-ButtonTexts` | — | Replace the button-name match list entirely |
| `-FallbackSeconds` | `30` | Interval of the fallback sweep (`0` disables it — not advised) |
| `-MinScanIntervalMs` | `200` | Minimum gap between two scans (coalesces event bursts) |
| `-RetryAfterMs` | `400` | Rescan delay after a missed first scan (`0` = no retry) |
| `-MaxSeconds` | `0` | Exit after N seconds (`0` = run until Ctrl+C) |
| `-DryRun` | off | Log which button *would* be clicked, click nothing |
| `-Probe` | off | Dump the chrome UI control tree into the log |
| `-LogFile` | `%TEMP%\pi-auto-allow.log` | Log path |
| `-MutexName` | `Global\pi-auto-allow-remote-debugging` | Single-instance mutex |

## Known pitfalls (Windows PowerShell 5.1 / Win11)

1. **.ps1 files with non-ASCII characters must be UTF-8 with BOM**, otherwise PS 5.1 misreads them as ANSI/GBK and produces phantom parse errors (this repo's script ships with BOM).
2. Multi-level nested `New-Object X(...)` parentheses fail with `Unexpected token ')'` — flatten into separate variables.
3. Structure-changed events require `AddStructureChangedEventHandler` (`AddAutomationEventHandler` with `StructureChangedEvent` throws "eventId not valid").
4. When querying/killing processes by command-line pattern, **the querying process matches itself** (its `-Command` string contains the pattern) — always exclude `$PID`.
5. **Silent death after Win10→Win11 upgrade**: `New-ScheduledTaskSettingsSet` defaults to `IdleSettings.StopOnIdleEnd=true` — the task gets terminated once the machine goes idle (~10 min without input). Once the watcher dies, the logon trigger won't fire again until the **next logon**, so popups go unanswered — looks exactly like "the script broke after the upgrade". `register-task.ps1` now disables that switch explicitly and adds a 30-min heartbeat trigger + restart-on-failure as a safety net; after an OS upgrade, just re-run `register-task.ps1` once. Also note: the heartbeat's `RepetitionDuration` must not be `[TimeSpan]::MaxValue` (it serializes to P99999999DT23H59M59S, which the Task Scheduler rejects as out of range) — use a finite, long-enough duration instead.
6. **On Win11 the default terminal is Windows Terminal, which ignores `-WindowStyle Hidden`**: every scheduled-task launch of the watcher pops up a visible console window in WT, and the heartbeat re-triggers it every 30 min. `register-task.ps1` now launches via `conhost.exe --headless powershell.exe ...` — forcing headless console hosting and bypassing the WT console handoff, so no window ever appears; systems whose default terminal is still the classic conhost (e.g. Win10) are unaffected.
7. **Never register a WinEvent/UIA callback as a PowerShell scriptblock.** Scriptblock delegates dispatched from threadpool threads silently never fire under PS 5.1 — the hook appears installed, the log stays empty, and it looks like "the dialog never appeared". Put the delegate and the state it reads in C# (a static delegate + static fields) and only the message pump in PowerShell.
8. **The watcher must run in the interactive session.** From session 0 (a service, or an SSH session) `AutomationElement.RootElement.Children` contains **no** browser windows at all — UIA cannot see another session's windows. Any "it finds zero windows" observation from such a context is meaningless.
9. **The browser does not always write `DevToolsActivePort`**: with a fresh profile plus an explicit `--remote-debugging-port`, the port listens but the file is never created. Detect liveness by probing the port / `/json/version`, not by waiting for that file.
10. **A task action that launches a `.ps1` from `C:\Windows\Temp` fails** (task result `0x1`, or `0xFFFD0000` for a `-File` action) even though the same command works interactively — keep the script next to `register-task.ps1` where it belongs, or inline it into the action as a base64 `-EncodedCommand`.

## Alternatives compared

| Approach | Pros | Cons |
|---|---|---|
| **This script (UIA watcher)** | Keeps daily-profile logins; fully automatic | Resident process ~75MB; automates away a security confirmation (see below) |
| Launch flags `--remote-debugging-port=9222 --user-data-dir=...` | No dialog, no resident process | Recent Chromium **ignores** the flag on the default user-data dir — needs a separate dir → no daily logins |
| Click once manually | Safest | Edge 151/155 re-prompts for every new CDP connection; every browser restart means another click |
| Group policy `RemoteDebuggingAllowed` | Official | Can only disable remote debugging entirely; no "auto-consent" |

## ⚠️ Security notice

Running this script automates away the browser's remote-debugging consent. **Any program that can execute code as your user can silently gain full control of the browser** (including cookies of every logged-in site). Use only on machines where you accept that risk.

Two things make this sharper than it sounds. First, because of the known limitation
above, a scan currently reaches into page content — so in principle a hostile page could
try to plant matching UI and get itself clicked, though the click target is always
resolved as a `Button` control named exactly `Allow` / `允许` inside a window whose
process is `msedge`/`chrome`. Second, the script answers a prompt *on your behalf*
without telling you, so you will not notice a new connection being authorised.

## License

[MIT](LICENSE)

# Win10 Desktop Beautifier

[![简体中文](https://img.shields.io/badge/语言-简体中文-red)](README.zh-CN.md) [![English](https://img.shields.io/badge/lang-English-blue)](README.md)

Taskbar icon centering + transparency and Start-menu tile beautification for **Windows 10** —
no system files modified, fully reversible, near-zero idle resource usage, and no resident
process by default.

Everything is driven by one interactive menu that **follows your system language
(Chinese / English, auto-detected)**.

---

## Features

**Taskbar**
- Icon centering (Win11-style, relative to the screen) on every monitor, mixed-DPI aware
- Transparency styles: **Clear** (fully transparent) / **Blur** / **Acrylic**
- Survives explorer restarts with **< 1 s** recovery via an optional event-driven watcher
- Persists across logons through a **one-shot** startup entry (`TaskbarWatcher.exe --apply-once`,
  ~20 ms of real work) — no resident PowerShell, no resident watcher unless you opt in

**Start menu**
- Uniform tile background color (transparent-following-theme, or any RGB)
- Normalized tile icons: each app's icon re-rendered with uniform padding, so tiles stop
  looking like a patchwork
- Optional hidden tile labels; one-click full restore

**General**
- Interactive menu (bilingual) — the only file you need to know: `Taskbar-Tool.cmd`
- Everything reversible: memory-only effects + HKCU-only registry changes + backups on apply
- Measured, reproducible performance (`Benchmark` in the menu)

## Compatibility

| | |
|---|---|
| OS | Windows 10 22H2 (build 19045.6466 tested; 19041+ expected). Win10-only — Windows 11 has native centering |
| Privileges | Taskbar features: **no admin**. Start-menu beautify: **one UAC consent** (some apps live under Program Files) |
| PowerShell | 5.1 (built-in) |
| Displays | Multi-monitor OK; mixed DPI handled (Per-Monitor V2 awareness) |

## Quick start

1. Double-click **`Taskbar-Tool.cmd`**
2. The menu shows live status; pick a number:

```
        Win10 Desktop Beautifier — Taskbar + Start Menu
  ──────────────────────────────────────────
   Centered icons : [√] centered (off by 0px)
   Taskbar style  : Clear (2026-10-02 13:08)
   Run at logon   : startup folder (logon)
   Live recovery  : not installed (optional)
  ──────────────────────────────────────────
   [1] Enable centered + fully transparent (recommended)
   [2] Change transparency style (clear / blur / acrylic)
   [3] Restore Windows defaults (undo all)
   [4] Run at logon: on / off
   [5] Live-recovery watcher: on / off
   [6] Benchmark
   [7] Start menu beautifier (uniform tiles/icons)
   [0] Exit
```

Logon persistence is installed by default as a **one-shot** entry (runs at logon, applies,
exits — nothing stays resident). The optional watcher (menu `[5]`, ~13 MB RAM, 0% idle CPU)
additionally restores everything within ~1 s after explorer restarts or resolution changes.

## Command line (optional)

```powershell
app\Win10-Taskbar-Tweak.ps1 -Center -Transparency Clear        # center + fully transparent now
app\Win10-Taskbar-Tweak.ps1 -Center -Transparency Blur         # blur style
app\Win10-Taskbar-Tweak.ps1 -Restore                           # undo everything
app\Win10-Taskbar-Tweak.ps1 -InstallScheduledTask              # install logon persistence (auto-fallback)
app\Win10-Taskbar-Tweak.ps1 -InstallWatcher                    # optional resident watcher
app\Win10-Taskbar-Tweak.ps1 -Benchmark                         # measured performance
app\Win10-Taskbar-Tweak.ps1 -Menu -Lang en                     # force UI language (auto|zh|en)

app\Start-Menu-Tweak.ps1 -Status                               # pinned apps, applied state
app\Start-Menu-Tweak.ps1 -Beautify -NormalizeIcons             # uniform colors + normalized icons
app\Start-Menu-Tweak.ps1 -Beautify -Color 17171A -HideLabels   # custom color, no labels
app\Start-Menu-Tweak.ps1 -Restore                              # undo start-menu changes
```

## How it works

**Taskbar centering** — `SetWindowPos` on `MSTaskListWClass` (the icon list window inside the
taskbar). On build 19045 the position sticks until the taskbar window is recreated (explorer
restart / resolution or DPI change / sign-out), which is exactly what the logon one-shot and the
optional watcher cover. Centering math uses the real usable interval — the News & Interests
widget overlays the rebar, so the right bound is measured from actual sibling windows.

**Transparency** — `SetWindowCompositionAttribute` with an `ACCENT_POLICY`
(`WCA_ACCENT_POLICY = 19`). Measured gotcha on 19045: `ACCENT_ENABLE_TRANSPARENTGRADIENT`
must be combined with `ACCENT_FLAG_GRADIENT_COLOR (0x2)` or DWM paints an **opaque** system
accent color. `GradientColor` is `0xAABBGGRR` (R/B swapped vs. ARGB).

**Logon persistence** — a Startup-folder entry runs `TaskbarWatcher.exe --apply-once` and exits.
Scheduled-task registration is attempted first (logon + unlock triggers) and automatically falls
back to the Startup folder on systems that restrict task creation for standard users.

**Optional watcher** — a 13 KB .NET executable using `SetWinEventHook`: taskbar
`EVENT_OBJECT_LOCATIONCHANGE` is filtered to the explorer process; `CREATE/DESTROY` are global
(low-frequency) so an explorer restart is noticed within ~1 s. Timers: a 150 ms debounce that
only runs while events arrive, plus a tiered 15 s guard (accent-only refresh, full re-apply once
a minute). Idle CPU: **0%**.

**Start menu** — desktop-app tile appearance is controlled by a
`<appname>.exe.VisualElementsManifest.xml` next to each app's exe. The tool writes these in bulk
(uniform `BackgroundColor`, optional normalized `Square150x150Logo`/`Square70x70Logo` PNGs
rendered from each app's icon), touches the shortcuts and restarts
`StartMenuExperienceHost`. All manifests are backed up and removable.

## Measured performance (build 19045.6466)

| Item | Measured | Notes |
|---|---|---|
| Full apply (center + transparency) | **29–31 ms** | `SetWindowPos` + accent + MSAA measurement |
| MSAA icon-width measurement | 5.44 ms/call | watcher only, on taskbar changes |
| Transparency (accent) apply | 0.63 ms/call | idempotent |
| Logon apply (`--apply-once` wall clock) | ~1020 ms | **~20 ms real work**, rest is .NET process startup; async & hidden |
| Watcher idle CPU | **0%** (0 ms in 30 s) | event-driven; timers parked when idle |
| Watcher memory | **12.7 MB** private | .NET Framework 4, no window, no tray icon |
| Explorer-restart recovery | **< 1 s** | global CREATE events notice the new taskbar instantly |
| PowerShell fallback cost | 328 ms | only if the exe is missing |

## Start-menu limitations (this Windows build)

These are **measured** constraints of 19045.6466, not tool bugs:

- The layout is stored in **CloudStore** (`windows.data.unifiedtile.*` registry blobs, opaque);
  the classic `start2.bin` no longer exists. Tile **positions** therefore cannot be safely
  automated — rearranging tiles stays manual.
- Tile appearance is snapshotted **at pin time**. After beautifying, already-pinned tiles need a
  re-pin (right-click tile → *Unpin from Start* → right-click the app in All-apps → *Pin to
  Start*; it lands at the end of the group). **Newly pinned apps pick up the unified look
  automatically.**
- Programmatic refresh is blocked by the OS: the unpin shell verb returns `E_ACCESSDENIED`,
  the CoreWindow exposes an empty UIA tree, and `Import-StartLayout` requires admin + a real
  image mount.
- UWP/Store tiles and `.url` web tiles cannot be restyled (of 72 tiles on the test machine,
  34 desktop-app tiles are covered).

## Restore / uninstall

- Menu `[3]` (taskbar) and `[7] → [2]` (start menu) revert everything; `Uninstall.cmd`-style
  one-click isn't needed — the menu paths also remove the logon entry and the watcher.
- Registry: only `HKCU` values are touched, and only after a snapshot was written to
  `app\backup\` (`-Restore` re-imports it).
- The taskbar transparency itself is memory-only — a `state 0` accent or an explorer restart
  returns the stock look.

## Project structure

```
Taskbar-Tool.cmd                  ← the only entry point (bilingual menu)
app\
  Win10-Taskbar-Tweak.ps1         ← taskbar: apply/restore/menu/benchmark/persistence
  TaskbarWatcher.cs / .exe        ← optional lightweight resident watcher (+ --apply-once)
  build.cmd                       ← compiles the watcher with the system csc.exe
  Start-Menu-Tweak.ps1            ← start menu: beautify/restore/status
  StartMenu-Elevated.ps1          ← elevated helper (manifests + icon normalization)
  StartMenu\work | backup         ← machine-local exports, logs, backups (gitignored)
  backup\                         ← registry snapshots (gitignored)
docs\NOTES.zh-CN.md               ← detailed Chinese engineering notes (earlier rounds)
```

## Building the watcher from source

The committed `TaskbarWatcher.exe` is built from the included `TaskbarWatcher.cs` — verify or
rebuild it yourself, no toolchain needed beyond Windows:

```cmd
app\build.cmd
```

## Contributing

Issues and PRs welcome. Code comments are currently mostly Chinese; English translations are
welcome. Batch files and PowerShell scripts **must** stay UTF-8 **with BOM** (Windows PowerShell
5.1 parses BOM-less files in the legacy ANSI codepage — this bit us several times).

## License

[MIT](LICENSE)

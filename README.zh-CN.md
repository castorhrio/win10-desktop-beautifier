# Win10 桌面美化工具

[![简体中文](https://img.shields.io/badge/语言-简体中文-red)](README.zh-CN.md) [![English](https://img.shields.io/badge/lang-English-blue)](README.md)

面向 **Windows 10** 的任务栏图标居中 + 透明、开始菜单磁贴美化工具——
不改系统文件、全程可逆、默认零常驻进程，空闲资源占用≈0。

交互菜单**自动跟随系统语言（中文/English）**，唯一需要认识的文件：`Taskbar-Tool.cmd`。

---

## 功能

**任务栏**
- 图标居中（Win11 观感，按屏幕居中），多显示器 + 混合 DPI 支持
- 透明样式：**Clear**（接近全透明）/ **Blur**（毛玻璃）/ **Acrylic**（亚克力）
- 可选事件驱动 watcher：explorer 重启后 **< 1 秒**自动恢复
- 登录生效用**一次性**启动项（`TaskbarWatcher.exe --apply-once`，实际工作 ~20ms），默认无常驻

**开始菜单**
- 统一磁贴底色（透明跟随主题，或指定颜色）
- 规范化磁贴图标：提取应用图标统一留白居中，解决"有的撑满、有的很小"的观感问题
- 可选隐藏磁贴名称；一键还原

**通用**
- 全部改动可逆：效果在内存、注册表只动 HKCU 且先备份
- 性能可复现：菜单内置 `性能测试`

## 兼容性

| | |
|---|---|
| 系统 | Windows 10 22H2（实测 19045.6466，预期 19041+）；仅 Win10——Win11 原生支持居中 |
| 权限 | 任务栏功能**免管理员**；开始菜单美化需**一次 UAC**（部分应用在 Program Files） |
| PowerShell | 5.1（系统自带） |
| 显示器 | 多屏 OK；混合 DPI 已处理（Per-Monitor V2） |

## 快速开始

1. 双击 **`Taskbar-Tool.cmd`**
2. 菜单实时显示状态，按数字操作：

```
        Win10 桌面美化 —— 任务栏 + 开始菜单
  ──────────────────────────────────────────
   图标居中      : [√] 已居中（偏差 0px）
   任务栏透明    : Clear (2026-10-02 13:08)
   开机自动生效  : 启动文件夹（登录）
   即时恢复      : 未安装（可选）
  ──────────────────────────────────────────
   [1] 开启 居中 + 全透明（推荐）
   [2] 更换透明样式（全透 / 毛玻璃 / 亚克力）
   [3] 恢复系统默认（取消全部效果）
   [4] 开机自动生效：开 / 关
   [5] 即时恢复 watcher：开 / 关
   [6] 性能测试
   [7] 开始菜单美化（统一磁贴底色/图标）
   [0] 退出
```

登录生效默认安装为**一次性运行**（登录时应用完自动退出，无常驻）。可选 watcher（菜单 `[5]`，
约 13MB 内存、空闲 0% CPU）额外覆盖 explorer 重启/改分辨率场景，约 1 秒内恢复。

## 命令行（可选）

```powershell
app\Win10-Taskbar-Tweak.ps1 -Center -Transparency Clear        # 立即 居中+全透明
app\Win10-Taskbar-Tweak.ps1 -Center -Transparency Blur         # 毛玻璃
app\Win10-Taskbar-Tweak.ps1 -Restore                           # 全部还原
app\Win10-Taskbar-Tweak.ps1 -InstallScheduledTask              # 安装登录自启（自动回退）
app\Win10-Taskbar-Tweak.ps1 -InstallWatcher                    # 可选常驻 watcher
app\Win10-Taskbar-Tweak.ps1 -Benchmark                         # 性能测试
app\Win10-Taskbar-Tweak.ps1 -Menu -Lang zh                     # 强制界面语言（auto|zh|en）

app\Start-Menu-Tweak.ps1 -Status                               # 查看固定应用与已应用状态
app\Start-Menu-Tweak.ps1 -Beautify -NormalizeIcons             # 统一底色 + 规范化图标
app\Start-Menu-Tweak.ps1 -Beautify -Color 17171A -HideLabels   # 自定义颜色 + 隐藏磁贴名称
app\Start-Menu-Tweak.ps1 -Restore                              # 还原开始菜单
```

## 实现原理

**任务栏居中** — 对任务栏内的 `MSTaskListWClass`（图标列表窗口）`SetWindowPos`。实测 19045 上
位置会保持到任务栏窗口重建（explorer 重启 / 分辨率或 DPI 变化 / 注销）——恰好被登录一次性自启和
可选 watcher 覆盖。居中计算用真实可用区间（右侧以资讯/天气组件、托盘等实际兄弟窗口为界，
rebar 会延伸到组件下面，直接按父窗口宽度居中会偏右）。

**透明** — `SetWindowCompositionAttribute` + `ACCENT_POLICY`（`WCA_ACCENT_POLICY=19`）。
19045 实测坑：`ACCENT_ENABLE_TRANSPARENTGRADIENT` 必须带 `ACCENT_FLAG_GRADIENT_COLOR (0x2)`，
否则 DWM 画成**不透明**系统强调色；`GradientColor` 字节序是 `0xAABBGGRR`（与 ARGB 相反）。

**登录生效** — 启动文件夹里的一次性运行。优先尝试注册计划任务（登录+解锁双触发），本机等限制
标准用户建任务的系统会自动回退到启动文件夹。

**可选 watcher** — 13KB 的 .NET 程序，`SetWinEventHook`：任务栏 `LOCATIONCHANGE` 事件按 explorer
进程过滤；`CREATE/DESTROY` 全局监听（低频）以便 explorer 重启约 1 秒内被感知。定时器：150ms 去抖
（仅在事件到来时启动）+ 分档 15s 兜底（平时只补 accent，约 1 分钟一次全量自愈）。空闲 CPU **0%**。

**开始菜单** — 桌面应用的磁贴外观由 exe 旁的 `<应用名>.exe.VisualElementsManifest.xml` 决定。
工具批量写入（统一 `BackgroundColor`、可选的规范化 `Square150x150Logo/Square70x70Logo` PNG——
从每个应用的图标提取重绘），触碰快捷方式并重启 `StartMenuExperienceHost`。所有清单均先备份、可删。

## 性能实测（19045.6466）

| 项目 | 实测值 | 说明 |
|---|---|---|
| 全量应用（居中+透明） | **29–31 ms** | `SetWindowPos` + accent + MSAA 测量 |
| MSAA 图标宽度测量 | 5.44 ms/次 | watcher 专用，任务栏变化时才调用 |
| accent 应用 | 0.63 ms/次 | 幂等 |
| 登录自启（exe 墙钟） | ~1020 ms | **实际工作 ~20ms**，其余为 .NET 进程启动；异步隐藏运行 |
| watcher 空闲 CPU | **0%**（30 秒 0ms） | 事件驱动，空闲时定时器停用 |
| watcher 内存 | **12.7 MB**（私有） | .NET Framework 4，无窗口无托盘 |
| explorer 重启恢复 | **< 1 秒** | 全局 CREATE 事件即时感知 |
| PowerShell 回退自启 | 328 ms | 仅 exe 缺失时的回退路径 |

## 开始菜单的限制（这版系统实测）

以下是 19045.6466 的**系统实测限制**，不是工具缺陷：

- 布局存储于 **CloudStore**（`windows.data.unifiedtile.*` 注册表二进制块，不可解析），
  经典的 `start2.bin` 已不存在。因此磁贴**位置**无法安全自动化，重排仍需手动拖动。
- 磁贴外观在**固定那一刻**被快照。应用美化后，已固定的磁贴需要重新固定才会换新装
  （右键磁贴 → 从"开始"屏幕取消固定 → 所有应用里右键该应用 → 固定到"开始"屏幕，会排到分组末尾）。
  **新固定的应用自动使用统一外观。**
- 程序化刷新被系统封死（均实测）：取消固定的 shell 动词返回 `E_ACCESSDENIED`；CoreWindow 的
  UIA 树为空；`Import-StartLayout` 需要管理员 + 真实镜像挂载。
- UWP/商店磁贴与 .url 网络磁贴不支持（实测机器 72 个磁贴中 34 个桌面应用可美化）。

## 还原 / 卸载

- 菜单 `[3]`（任务栏）与 `[7] → [2]`（开始菜单）即可全部还原，同时移除登录自启与 watcher。
- 注册表只动 HKCU，且应用前已快照到 `app\backup\`（`-Restore` 会导回）。
- 任务栏透明本身是内存态——accent 归零或重启 explorer 即恢复系统原样。

## 项目结构

```
Taskbar-Tool.cmd                  ← 唯一入口（中英文双语菜单）
app\
  Win10-Taskbar-Tweak.ps1         ← 任务栏：应用/还原/菜单/性能测试/持久化
  TaskbarWatcher.cs / .exe        ← 可选轻量常驻 watcher（兼 --apply-once）
  build.cmd                       ← 用系统自带 csc.exe 编译 watcher
  Start-Menu-Tweak.ps1            ← 开始菜单：美化/还原/状态
  StartMenu-Elevated.ps1          ← 提权辅助（写清单 + 图标规范化）
  StartMenu\work | backup         ← 机器本地导出/日志/备份（不入库）
  backup\                         ← 注册表快照（不入库）
docs\NOTES.zh-CN.md               ← 详细中文工程笔记（前几轮的实测记录）
```

## 从源码编译 watcher

仓库内的 `TaskbarWatcher.exe` 由随附的 `TaskbarWatcher.cs` 编译——可自行校验或重编，
无需安装任何工具链：

```cmd
app\build.cmd
```

## 参与贡献

欢迎 Issue 与 PR。代码注释目前以中文为主，欢迎翻译。批处理与 PowerShell 脚本**必须**保存为
带 **BOM 的 UTF-8**（Windows PowerShell 5.1 会按 ANSI 读取无 BOM 文件——我们踩过多次）。

## 许可证

[MIT](LICENSE)

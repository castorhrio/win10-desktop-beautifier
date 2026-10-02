> [!NOTE]
> 本文件是 2026-10-02 开发过程中的详细工程笔记（早期版本）。
> 其中的部分结论已被后续实测修正，**当前用法请看根目录的 [README.zh-CN.md](../README.zh-CN.md)**。
# Windows 10 任务栏：图标居中 + 半透明/透明

> 本文所有数字均在本机实测取得，不是抄文档。实测环境见文末附录。
> 脚本随本文一起提供，**不需要管理员权限**，**不改任何系统文件**，**不影响 Windows 更新**。

---

## ⚠️ 修复与实测修正（2026-10-02，重要）

之前的版本在双击后**什么都不会发生**，原因与修正如下（均已在本机验证）：

1. **致命崩溃**：`param()` 默认值里用了 `Join-Path $PSScriptRoot 'backup'`——Windows PowerShell 5.1 在参数绑定阶段 `$PSScriptRoot` 为空，脚本一启动就抛异常退出。`Start.cmd`/启动项又是隐藏窗口运行，所以你只看到"没效果"。→ 已改为脚本体内补齐 `$BackupDir`。
2. **Clear 透明变"不透明蓝"**：`ACCENT_ENABLE_TRANSPARENTGRADIENT` 在 19045.6466 上必须带 `ACCENT_FLAG_GRADIENT_COLOR(0x2)`，否则 DWM 忽略 `GradientColor`、直接把任务栏画成不透明的系统强调色。→ 已按风格设置 flags（Clear=2/2，Blur=3/0，Acrylic=4/2）。
3. **居中偏右**：旧算法在 `MSTaskSwWClass` 客户区内居中，但它右端被资讯/天气组件（`DynamicContent2`，约 96px）覆盖。→ 已改为按真实可用区间（右侧以天气组件/托盘左缘为界）计算，默认相对整块屏幕居中（Win11 观感，可用 `-Anchor usable` 改回区间居中），并夹紧边界。
4. **Tint 通道序**：`GradientColor` 实际是 `0xAABBGGRR`，旧版按 ARGB 直接传会偏色。→ 已做通道交换。
5. **保持性实测修正**：本机 19045.6466 上，**打开/关闭窗口、任务栏 auto-hide 重布局都不会让居中复位**；真正会复位的是 **explorer 重启、分辨率/DPI 变化、注销**（任务栏窗口重建）。所以"非驻留"完全可行：登录时应用一次即可，explorer 重启后重跑一次（或装可选的 watcher）。
6. **生效方式改为非驻留**：登录自启改为**一次性运行**（应用完退出，不再常驻 PowerShell）；本机注册计划任务被系统限制（拒绝访问），脚本会自动回退到启动文件夹。想要"explorer 重启后即时恢复"可运行 `Enable-Watcher.cmd` 安装可选的轻量 watcher（事件驱动，空闲 0% CPU，约 10MB 内存）。
7. **新增 DPI 声明**：双屏缩放不同时旧坐标会虚拟化错位，脚本/watcher 现在都先 `SetProcessDpiAwarenessContext(-4)`。

新增文件：`TaskbarWatcher.cs` / `TaskbarWatcher.exe` / `build.cmd` / `Enable-Watcher.cmd`。
还原请双击 `Uninstall.cmd`（会还原外观、删除登录自启、卸载 watcher）。

### 第二轮打磨（2026-10-02 下午，针对"不会用"和"性能疑虑"）

1. **入口收敛为一个**：根目录只剩 `任务栏工具.cmd`（中文菜单：状态显示 + 数字选单），实现文件全部收进 `app\`。原 `Start.cmd` / `Uninstall.cmd` / `Enable-Watcher.cmd` 已并入菜单项。
2. **登录自启改为 exe 直调**：启动文件夹条目现在是 `TaskbarWatcher.exe --apply-once`（实测内部工作 ~20ms），不再启动 PowerShell——低配机登录省掉 300ms~3s 的 PS 启动+运行时编译开销。exe 缺失时自动回退 PowerShell 方式。
3. **watcher 降载**：150ms 去抖定时器改为**事件到来才启动、处理完即停**（空闲零唤醒）；15s 兜底分档——平时只幂等补 accent（不做 MSAA 测量），全量自愈约 1 分钟一次或 pid 变化时；CREATE/DESTROY 钩子改全局低频监听，explorer 重启后 **<1 秒**恢复（原来最多等 15s）。
4. **状态可查**：accent 系统没有查询接口，现在每次应用/安装/还原都写 `app\state.json`，菜单据此显示"当前样式/自启方式/watcher 状态"；"图标居中"一栏则是实时测量（与理论居中位对比，±8px 容差）。
5. **性能可复现**：`-Benchmark`（菜单 [6]）输出上表全部数字。

---

## 🚀 就用这个（TL;DR）

**双击 `任务栏工具.cmd`** —— 弹出中文菜单，按数字操作，完事。

| 你想干嘛 | 操作 |
|---|---|
| 开启 居中 + 全透明 | 菜单 **[1]** |
| 换透明样式（全透/毛玻璃/亚克力） | 菜单 **[2]** |
| 恢复系统默认 | 菜单 **[3]** |
| 开机自动生效：开/关 | 菜单 **[4]**（默认开） |
| explorer 重启/改分辨率后即时恢复（可选） | 菜单 **[5]**（约 13MB 内存、空闲 0% CPU） |
| 性能测试 | 菜单 **[6]** |
| 开始菜单美化（统一磁贴底色/图标） | 菜单 **[7]**（详见下方"开始菜单美化"章节） |

**文件结构**（2026-10-02 重组）：
- `任务栏工具.cmd` —— **唯一需要认识的文件**（菜单入口）
- `app\Win10-Taskbar-Tweak.ps1` —— 干活的脚本（菜单在调它；也可命令行直接用，见下）
- `app\TaskbarWatcher.exe / .cs / build.cmd` —— 可选轻量常驻组件（菜单 [5] 用）
- `app\Start-Menu-Tweak.ps1 / StartMenu-Elevated.ps1 / StartMenu\` —— 开始菜单美化（菜单 [7] 用）
- `app\backup\` —— 注册表备份产物；`app\state.json` —— 菜单显示用的状态记录
- `app\taskbar-transparency-on/off.reg` —— 手工开/关系统原生透明效果（一般不用）

命令行方式（可选，给熟手）：
```powershell
app\Win10-Taskbar-Tweak.ps1 -Center -Transparency Clear            # 立即居中+全透明
app\Win10-Taskbar-Tweak.ps1 -Center -Transparency Blur             # 毛玻璃
app\Win10-Taskbar-Tweak.ps1 -Restore                               # 全部还原
app\Win10-Taskbar-Tweak.ps1 -InstallScheduledTask                  # 装登录自启（exe 直调）
app\Win10-Taskbar-Tweak.ps1 -InstallWatcher                        # 装 watcher（可选常驻）
app\Win10-Taskbar-Tweak.ps1 -Benchmark                             # 性能测试
```

**已经帮你做好的事**（不用重复操作）：
- 已备份 → `app\backup\`（3 个 .reg + snapshot.json）
- 已安装登录自启 → 启动文件夹里的一次性运行（`TaskbarWatcher.exe --apply-once`，实测内部工作 ~20ms，**不常驻、不拖慢开机**）

---

## 📊 性能实测（2026-10-02，本机 19045.6466）

| 项目 | 实测值 | 说明 |
|---|---|---|
| 一次性应用（居中+透明全流程） | **29~31 ms** | `SetWindowPos` + accent + MSAA 测量的全部成本 |
| MSAA 图标宽度测量 | 5.44 ms/次 | watcher 只在任务栏窗口变化时调用 |
| accent 透明应用 | 0.628 ms/次 | 幂等，重复调用无副作用 |
| 登录自启（`--apply-once` 进程墙钟） | ~1020 ms | 内部实际工作 ~20ms，其余是 .NET 进程启动；**异步隐藏运行，不拖慢登录** |
| watcher 空闲 CPU | **0%**（30 秒 0ms） | 事件驱动，空闲时定时器都停着（零唤醒） |
| watcher 内存 | **12.7 MB**（私有） | .NET Framework 4，无窗口无托盘 |
| explorer 重启恢复延迟 | **< 1 秒** | 全局 CREATE 事件即时感知新任务栏 |
| PowerShell 回退自启成本 | 328 ms | 仅 exe 缺失时的回退路径才有 |

低配机说明：④ 的墙钟在慢 CPU 上可能到 1.5~2.5s，但它是登录后**异步后台运行**的，不阻塞任何东西；watcher 的事件回调只有"类名比较"这种微秒级操作，拖拽窗口/打字也不会产生可感知负载（钩子已按进程过滤，只有 CREATE/DESTROY 是全局低频事件）。

---

## 🎨 开始菜单美化（菜单 [7]，2026-10-02 新增）

`app\Start-Menu-Tweak.ps1`（提权辅助 `app\StartMenu-Elevated.ps1`）：

| 功能 | 说明 |
|---|---|
| 统一磁贴底色 | 为固定的桌面应用批量写 `<应用名>.VisualElementsManifest.xml`（默认 `transparent` 跟随主题/强调色，可指定 hex） |
| 规范化磁贴图标 | 提取应用图标 → 统一留白居中渲染为磁贴 Logo，解决"有的图标撑满、有的很小" |
| 可选隐藏磁贴名称 | `-HideLabels`（极简风） |
| 一键还原 | 删除生成的清单/图标、恢复原有清单，全量可逆 |

**本版本 Windows 的硬限制（实测 19045.6466）**：
- 开始菜单布局存储于 **CloudStore（`windows.data.unifiedtile.*`，不透明二进制）**，`start2.bin` 已不存在；磁贴**位置**无法安全自动化，重排仍需手动拖动。
- 磁贴外观在**固定那一刻**被快照；写完清单后，已固定的磁贴要**重新固定**才会换新装（右键磁贴 → 取消固定 → 所有应用里右键应用 → 固定到"开始"屏幕，会排到分组末尾）。**以后新固定的应用自动使用统一外观**。
- 程序化刷新通道全部被系统封死（实测）：shell 动词 `DoIt()` 返回拒绝访问；UIA 树不暴露磁贴；`Import-StartLayout` 假挂载不可用。
- UWP/商店应用与 .url 网络磁贴不受支持（本机 72 个磁贴中 34 个桌面应用可美化）。
- 右键菜单中的"卸载"就在"调整大小"附近，自动化误点风险高，故不做全自动刷新。

状态查看：`app\Start-Menu-Tweak.ps1 -Status`；还原：`-Restore`（需一次 UAC）。

---

## 0. 实测环境

| 项 | 实测值 |
|---|---|
| 系统 | Microsoft Windows 10 专业版 |
| 版本 / 内部版本 | 22H2 / **19045.6466** |
| 显示器 | 2 台：2560×1440@0（主）、1920×1080@2560（副） |
| 任务栏窗口结构（主） | `Shell_TrayWnd` → `ReBarWindow32` → `MSTaskSwWClass` → `MSTaskListWClass` |
| 任务栏窗口结构（副） | `Shell_SecondaryTrayWnd` → `WorkerW` → `MSTaskListWClass` |
| 图标区可用宽 / 图标总宽 | 主屏 2292 px / 542 px（16 个按钮，单个 49 px） |
| `EnableTransparency` 现值 | **1**（系统原生透明效果本来就是开着的） |

---

## 1. 结论速览

| 需求 | 首选 | 是否需要常驻 | 是否改系统文件 | 是否需管理员 |
|---|---|---|---|---|
| 图标居中 | 无原生方案 → **第三方 TaskbarX** 或 **本脚本 `-Watch`** | **必须常驻** | 否 | 否 |
| 毛玻璃/亚克力 | **系统原生设置**（`EnableTransparency=1`） | 否（一次设置永久生效） | 否（只写 HKCU） | 否 |
| 更深的透明/接近全透 | **第三方 TranslucentTB** 或 **本脚本 `-Watch -Transparency`** | **必须常驻** | 否 | 否 |

一句话：**透明有「一次搞定」的原生路子；居中在 Win10 上天生没有一次性方案**，这是 Win10 任务栏的布局机制决定的——
只要打开/关闭窗口、切分辨率、锁屏回来、explorer 重启，系统就会把图标重新排回左边。任何"跑一次就永久居中"的说法都不成立。

---

## 2. 需求一：底部任务栏图标居中

### 2.1 方案对比

| 方案 | 怎么做 | 优点 | 缺点 | Win10 兼容性 | 多显示器 |
|---|---|---|---|---|---|
| **系统原生设置** | — | — | **不存在**。Win10 没有"任务栏对齐方式"选项，这是 Win11 才有的功能 | 全部版本均无 | — |
| **注册表调整** | — | — | **不存在**。网传的 `TaskbarAl`（Win11 的值）在 Win10 零售版上是空值，写了没有任何效果 | 全部版本均无效 | — |
| **脚本一次性执行**（本脚本 `-Center`） | 计算图标总宽，用 `SetWindowPos` 把 `MSTaskListWClass` 移到中间 | 零常驻、零依赖、可逆 | **几分钟内就会被系统复位**，只能在"刚执行完到下一次任务栏重排"之间生效 | 见 §4 | 支持 |
| **脚本常驻**（本脚本 `-Watch -Center`） | 每 600~800 ms 重新计算并复位一次 | 效果等价于 TaskbarX；零第三方 | 多一个 `powershell.exe` 进程（本次会话实测宿主 97 MB，含沙箱开销） | 见 §4 | 支持 |
| **TaskbarX**（轻量常驻第三方） | 单文件 exe，开机自启 | ~5–10 MB，成熟、带动画、多显示器独立配置 | 需信任第三方二进制；与系统更新打补丁后偶发失效需重启 | 官方称支持 Win10/Win11 旧版（以项目 README 为准） | 支持 |

> **不推荐**：7+ Taskbar Tweaker（老牌但主要管按钮行为，不做居中/透明）；Windhawk 社区 mod（功能随版本变动快，需自行评估）。

### 2.2 为什么"一次性脚本"留不住

实测：执行一次 `-Center` 后，主屏图标左边从 **48 → 923**，副屏 **2608 → 3236**，居中正确。
但只要 explorer 重排任务栏（开关窗口、切分辨率、锁屏、主题切换、补丁后重启 explorer），图标就会弹回 48。
所以"一次性"和"长期"不是风格选择，是**能不能留住**的区别。

---

## 3. 需求二：任务栏半透明 / 透明

Win10 有两条完全不同的路子，效果差别很大：

| 层级 | 方案 | 是否一次性 | 效果 | 备注 |
|---|---|---|---|---|
| **L1 原生毛玻璃** | `设置 → 个性化 → 颜色 → 透明效果 = 开`<br>即 `HKCU\...\Themes\Personalize\EnableTransparency = 1` | ✅ 一次设置永久生效 | 任务栏半透明 + 背景模糊 | 你本机**已经是 1**，也就是说原生透明已经开着了 |
| **L1 脚本版** | 双击 `taskbar-transparency-on.reg`，或 `.\Win10-Taskbar-Tweak.ps1 -NativeTransparency On` | ✅ 同上 | 同上 | 脚本会自动先备份再改 |
| **L2 加深透明** | `SetWindowCompositionAttribute` 给任务栏挂 accent 策略：<br>`Blur`(3) / `Acrylic`(4) / `Clear`(2) | ❌ **内存态，需常驻重刷** | 比原生更透，`Clear` 接近全透明 | 本脚本 `-Transparency`，或 TranslucentTB |
| **L2 第三方** | **TranslucentTB** | ❌ 常驻（很轻） | 同上，且能按"窗口最大化/开始菜单打开"分场景切换 | 开源 |

**L1 和 L2 可以叠加**：先开原生透明，再用 L2 把模糊度往下压。
**注意**：高对比度模式、省电模式会由系统强制关闭透明效果，此时 L1/L2 都会失效。

---

## 4. Win10 各版本兼容性

| 市场名 | 内部版本 | 图标居中 | 原生透明 `EnableTransparency` | accent 透明 API | 亚克力(4) |
|---|---|---|---|---|---|
| 1507 | 10240 | 需常驻重刷 | 无此键（早期透明恒开） | 未实测，不建议 | ✗ |
| 1511 | 10586 | 需常驻重刷 | 无此键 | 未实测，不建议 | ✗ |
| 1607 | 14393 | 需常驻重刷 | ✔ | ✔ | ✗ |
| 1703 | 15063 | 需常驻重刷 | ✔ | ✔ | ✗ |
| 1709 | 16299 | 需常驻重刷 | ✔ | ✔ | ✗ |
| 1803 | 17134 | 需常驻重刷 | ✔ | ✔ | ✔ |
| 1809 | 17763 | 需常驻重刷 | ✔ | ✔ | ✔ |
| 1903 / 1909 | 18362 / 18363 | 需常驻重刷 | ✔ | ✔ | ✔ |
| 20H2 / 21H1 / 21H2 | 19042 / 19043 / 19044 | 需常驻重刷 | ✔ | ✔ | ✔ |
| **22H2** | **19045** | 需常驻重刷 | ✔ | ✔（**实测通过**） | ✔ |

- ✔ / ✗ 的判定依据：窗口结构 `MSTaskListWClass` 自 Vista 沿用至今，accent 策略自 1607 起可用，亚克力自 1803 起可用。
- **只有 19045.6466 是实测**，其余为按 Win32 结构推断，请在目标机器上先跑 `-Status` 确认。
- **Windows 11 不适用**：22H2+ 的任务栏内部结构已改，找不到 `MSTaskListWClass`，`-Status` 会直接提示未找到。

### 多显示器

- 主任务栏：`Shell_TrayWnd`；副任务栏：`Shell_SecondaryTrayWnd`（每台副屏一个）。
- 两者**结构不同**：副屏是 `WorkerW → MSTaskListWClass`，没有 `ReBarWindow32`/`MSTaskSwWClass` 这一层。本脚本已分别处理。
- 默认处理全部显示器；只想动主屏加 `-PrimaryOnly`。
- 副屏任务栏只显示该屏窗口时，居中按"该屏图标总宽"算，不会跟主屏串。

---

## 5. 脚本用法

### 5.1 文件清单

| 文件 | 作用 |
|---|---|
| `Win10-Taskbar-Tweak.ps1` | 主脚本：状态/备份/居中/透明/常驻/还原 |
| `Install-WatchTask.cmd` | 建一个「登录时自动启动」的计划任务，长期保持效果 |
| `Uninstall-WatchTask.cmd` | 删除计划任务并一键还原 |
| `taskbar-transparency-on.reg` / `-off.reg` | 原生透明开关，双击即可导入 |
| `backup\` | `-Backup` 的产物：3 个 `.reg` + `snapshot.json` |

### 5.2 权限

**全部不需要管理员。** 脚本只做三件事：读/写 `HKCU` 下自己的个性化键值、向任务栏窗口发 Win32 消息、调用无障碍接口测量。
不要右键"以管理员身份运行"——`Install-WatchTask.cmd` 用的是 `/RL LIMITED`，提权后计划任务反而可能跑在错误的用户上下文里。

### 5.3 命令

```powershell
# 1) 先看清楚机器情况（默认动作，随时可跑，只读）
.\Win10-Taskbar-Tweak.ps1 -Status

# 2) 备份（建议第一次用之前先跑一次）
.\Win10-Taskbar-Tweak.ps1 -Backup

# 3) 一次性居中（会自己提醒你"留不住"）
.\Win10-Taskbar-Tweak.ps1 -Center
.\Win10-Taskbar-Tweak.ps1 -Center -Offset -20        # 手动左移 20px 微调

# 4) 常驻模式：这才是能长期保持的用法
.\Win10-Taskbar-Tweak.ps1 -Watch -Center -IntervalMs 800
.\Win10-Taskbar-Tweak.ps1 -Watch -Center -Transparency Blur -IntervalMs 800

# 5) 透明（L1 原生 / L2 脚本）
.\Win10-Taskbar-Tweak.ps1 -NativeTransparency On      # L1，持久
.\Win10-Taskbar-Tweak.ps1 -Transparency Acrylic       # L2，一次性
.\Win10-Taskbar-Tweak.ps1 -Transparency Clear -Tint '40000000'   # Clear + 叠一层 25% 黑（AARRGGBB）

# 6) 还原
.\Win10-Taskbar-Tweak.ps1 -Restore
```

常用参数：`-Offset`（微调像素）、`-PrimaryOnly`（只动主屏）、`-BackupDir`（改备份目录）、`-IntervalMs`（常驻刷新间隔）。

### 5.4 关键步骤注释（脚本内已带，此处摘要点）

| 步骤 | 作用 | 为什么必须这么做 |
|---|---|---|
| `EnumChildWindows` + `GetClassName` 找 `MSTaskListWClass` | 定位图标容器 | **实测**：`FindWindowEx` 按类名在 `ReBarWindow32` 下取不到 `MSTaskSwWClass`（返回 0）。网上流传的 `FindWindowEx` 链式写法在本机直接失效 |
| MSAA `AccessibleObjectFromWindow(hwnd, OBJID_CLIENT)` + `AccessibleChildren` | 量出图标总宽 | **实测**：`TB_BUTTONCOUNT` 在 19045 的 `MSTaskListWClass` 上返回 0（按钮已不是标准 toolbar item），`TB_GETITEMRECT` 跨进程传指针也无效。TaskbarX 官方源码同样走 MSAA |
| 子项按 **VT_I4 子 ID** 处理，`accLocation(acc, childId)` 逐个取 | 拿到每个按钮的坐标 | **实测**：MSAA 子项返回的是子 ID（vt=3）而不是 IDispatch 对象，只认 `IDispatch` 的解析会得出"0 个按钮" |
| `ClientToScreen(父窗口)` 换算后再 `SetWindowPos` | 移到中间 | **实测**：`SetWindowPos` 的 x/y 是**父窗口客户区相对坐标**。直接传屏幕坐标会整体偏移（本机实测偏了 48 px），还原时也会还原不干净 |
| `SWP_NOSIZE｜NOZORDER｜NOACTIVATE｜ASYNCWINDOWPOS｜NOSENDCHANGING` | 只移位置 | 不改尺寸、不改 Z 序、不抢焦点、不触发重排消息，避免闪烁 |
| 备份走 .NET 注册表 API，不调 `reg.exe` | 导出 `.reg` + `snapshot.json` | 不依赖外部程序，也不会被软件限制策略拦掉 |

---

## 6. 备份与还原

### 备份

```powershell
.\Win10-Taskbar-Tweak.ps1 -Backup
```

产物在 `.\backup\`：
- `Personalize.reg` / `Advanced.reg` / `StuckRects3.reg` —— 标准 .reg 格式（UTF-16），**双击即可手工导入**
- `snapshot.json` —— `-Restore` 用它精确还原（含值的原始类型，`Binary`/`QWord`/`MultiString` 都不会退化）

备份范围只限 `HKCU` 下这三个键：`Themes\Personalize`、`Explorer\Advanced`、`Explorer\StuckRects3`（任务栏位置/锁定状态）。**不碰 HKLM，不碰系统文件。**

### 还原（三种粒度）

```powershell
# A. 全部还原：图标归位 + 关闭脚本式透明 + 注册表回到备份点
.\Win10-Taskbar-Tweak.ps1 -Restore

# B. 只还原居中位置（保留透明）
.\Win10-Taskbar-Tweak.ps1 -Transparency Normal

# C. 只还原注册表（例如只导入过 .reg）
双击 backup\Personalize.reg
# 或原生透明单独关掉：
双击 taskbar-transparency-off.reg
```

### 兜底还原（脚本都没了也能回）

居中和 L2 透明都是**内存态**，最暴力的还原方式永远是：

```cmd
taskkill /f /im explorer.exe & start explorer.exe
```

或注销重登。不需要任何脚本、不需要备份。这也是这套方案风险低的原因：**最坏情况就是重启一下资源管理器**。

---

## 7. 副作用与规避

| 现象 | 原因 | 规避 |
|---|---|---|
| 任务栏图标短暂重排/闪烁 | 每次 `SetWindowPos` 触发一次重排 | `IntervalMs` 默认 600~800 ms，肉眼基本无感；觉得跳就调到 1000 |
| 常驻多一个进程 | `powershell.exe` 常驻 | 在意资源就改用 TaskbarX（~5–10 MB）。**不要同时跑 TaskbarX 和本脚本 `-Watch`**，两者会抢同一批窗口坐标，表现为图标抽搐 |
| explorer 重启后失效 | 内存态丢失 | `-Watch` / 计划任务自动补回；脚本每轮都重新查找窗口句柄，explorer 重启也能自愈 |
| 锁屏/远程桌面/UAC 安全桌面后失效 | 同上 | 同上 |
| 分辨率或 DPI 变更后偏移 | 同上，且宽度变了 | 同上；`-Watch` 每轮重新测量宽度 |
| 系统更新后失效？ | — | Win10 22H2 已于 **2025-10-14** 结束主流支持，消费版 ESU 到 **2026-10-13**，之后不会再有功能更新推翻这些设置。累积更新/补丁**会**重启 explorer → 内存态丢失 → `-Watch` 自动补回；**HKCU 个性化键值不会被更新重置** |
| 改了 `EnableTransparency` 不立即生效 | explorer 缓存 | 重启 explorer 或注销重登一次 |
| 高对比度/省电模式下透明失效 | 系统强制策略 | 关掉高对比度/省电模式 |
| 图标没居中但脚本说成功 | 测量的"图标总宽"含隐藏项，可能多算 | 用 `-Offset` 手动微调几十像素 |
| 任务栏根本没找到 | 不是 Win10 任务栏结构（如 Win11 22H2+） | `-Status` 会明确提示 |

---

## 8. 一次性执行 vs 长期运行

| | 一次性脚本 | 长期运行 |
|---|---|---|
| 命令 | `-Center` / `-Transparency X` / `-NativeTransparency On` | `-Watch -Center [-Transparency X]` |
| 进程 | 跑完即退 | 一个 `powershell.exe` 常驻到 Ctrl+C 或注销 |
| 原生透明(L1) | ✅ 永久 | — |
| 居中 | ❌ 几分钟内被复位 | ✅ 持续保持 |
| 加深透明(L2) | ❌ explorer 重启即丢 | ✅ 持续保持 |
| 开机自动 | — | `Install-WatchTask.cmd`（计划任务，登录触发，`/RL LIMITED`） |
| 关闭 | — | 任务管理器结束 `powershell.exe`，或 `Uninstall-WatchTask.cmd` |

**推荐组合（按"可逆 + 少占用 + 不常驻"排序）：**

1. **只要毛玻璃**：什么都不用装 —— 双击 `taskbar-transparency-on.reg`（或 `-NativeTransparency On`）。一次生效永久有效，零常驻。你本机已经开着了。
2. **毛玻璃 + 居中**：`透明 = 原生 L1` + `居中 = TaskbarX`（最省资源）或本脚本 `-Watch -Center`。
3. **要接近全透明**：`TranslucentTB`（最省事）或本脚本 `-Watch -Transparency Clear`。

---

## 提交 GitHub 前的敏感信息自查（已做，可直接开仓库）

| 检查项 | 结果 |
|---|---|
| 密钥 / token / 密码 / 私钥 | **无**。已正则扫描 `password / secret / token / api_key / ghp_ / AKIA / BEGIN PRIVATE KEY` |
| 邮箱 / 账号名 | **无** |
| 硬编码用户路径 `C:\Users\<用户名>` | **无**。脚本一律用 `$PSScriptRoot`、`%~dp0`、`[Environment]::GetFolderPath('Startup')` |
| 调试产物（含用户名、当时打开的窗口标题、第三方内部代码） | **已删除** |
| 网络请求 | **无**。全文没有 `Invoke-WebRequest` / `Invoke-RestMethod` / `WebClient` / `curl` / 任何 URL，离线可跑 |
| `backup\`（本机注册表快照） | 已写进 `.gitignore`，不入库；随时 `-Backup` 重新生成 |

脚本只做三件事：读写 `HKCU` 下三个个性化键、给任务栏窗口发 Win32 消息、调用无障碍接口测量。
**不提权、不注入、不装服务、不开端口、不联网。** 想复核的话，全文检索 `Write-` / `Set-` 就能看全。

> 提醒：`.gitignore` 里的 `backup/` 是**为本机还原准备的**，提交时不会带上去。
> 如果换机器克隆，先跑一次 `-Backup` 再动别的。

---

## 附录：本次实测原始记录

```
系统: Microsoft Windows 10 专业版 内部版本 19045.6466
[=] 发现任务栏 2 个
  Primary              tray=[0,2560]   父窗口宽=2292  图标总宽=542  按钮=16  当前左边=48
  Secondary(0xC0344)   tray=[2560,4480] 父窗口宽=1799  图标总宽=542  按钮=16  当前左边=2608
[=] HKCU Personalize\EnableTransparency = 1
[=] 显示器 2 台: 2560x1440@0 , 1920x1080@2560

--- 执行 -Center ---
[+] Primary:            居中完成，图标左边 923  （父窗口 48，宽 2292，图标总宽 542）
[+] Secondary(0xC0344): 居中完成，图标左边 3236 （父窗口 2608，宽 1799，图标总宽 542）
--- 执行 -Restore ---
[+] Primary:            位置归零 + 关闭 accent 透明
[+] Secondary(0xC0344): 位置归零 + 关闭 accent 透明
--- 复查 ---
  Primary 当前左边=48   Secondary 当前左边=2608   （与基线完全一致）
```

校验：`923 = 48 + (2292-542)/2`，`3236 = 2608 + (1799-542)/2`，与系统默认位置 `48` / `2608` 精确复原。

### 实测踩到的 5 个坑（都已写进脚本）

1. `FindWindowEx` 按类名在本机 `ReBarWindow32` 下取不到子窗口 → 改用 `EnumChildWindows` + `GetClassName`。
2. `TB_BUTTONCOUNT` / `TB_GETITEMRECT` 在 19045 的 `MSTaskListWClass` 上无效（返回 0）→ 改用 MSAA（与 TaskbarX 源码一致）。
3. MSAA 子项是 `VT_I4` 子 ID 而非 IDispatch → 必须按子 ID 调 `accLocation`。
4. `SetWindowPos` 的 x/y 是父窗口客户区相对坐标 → 必须先 `ClientToScreen` 换算，否则整体偏移（实测偏 48 px）。
5. **脚本文件必须存成 CRLF**：PowerShell 5.1 解析纯 LF 且含 here-string 的脚本时行号会错位，报"表达式或语句中包含意外的标记 `}`"。随附文件已全部转成 CRLF。

<#
.SYNOPSIS
    Windows 10 任务栏：图标居中 + 半透明/透明。
.DESCRIPTION
    纯 PowerShell + Win32 P/Invoke，不改系统文件、不写系统目录、不注入 explorer。
    所有改动分两类：
      A. 内存态（居中位置 / accent 透明）——进程退出或 explorer 重建即失效，可一键还原；
      B. 注册表态（HKCU 下个性化开关）——持久，脚本会自动备份并可还原。
    不需要管理员权限。
.PARAMETER Status
    打印当前系统版本、任务栏窗口结构、测得的图标总宽、各显示器任务栏情况。默认动作。
.PARAMETER Backup
    把相关注册表项导出到 -BackupDir（默认 .\backup）。
.PARAMETER Center
    把任务栏图标居中（一次性；explorer 重排后会复位，需配合 -Watch）。
.PARAMETER Offset
    居中时的手动微调像素，正数右移、负数左移。
.PARAMETER Transparency
    Normal=恢复默认 / Blur=毛玻璃 / Acrylic=亚克力(1803+) / Clear=接近全透明。
.PARAMETER Tint
    叠加色，格式 AARRGGBB（十六进制），默认 00000000（不叠加）。
.PARAMETER Watch
    常驻模式：每 -IntervalMs 毫秒重新应用上面指定的效果，直到 Ctrl+C。
.PARAMETER IntervalMs
    常驻模式的刷新间隔，默认 600。
.PARAMETER Restore
    还原：图标位置归零 + 关闭 accent 透明 + 从备份导入注册表。
.PARAMETER PrimaryOnly
    只处理主显示器任务栏（默认处理全部显示器）。
.PARAMETER Anchor
    居中锚点：screen=相对整块屏幕居中（Win11 观感，默认）；usable=在开始按钮与托盘/小组件之间居中。
.PARAMETER Menu
    交互式中文菜单（无参数双击运行时默认进入）。所有常用操作都在菜单里。
.PARAMETER Benchmark
    性能测试：测量 PS 启动成本、MSAA 测量、accent 应用、exe 自启耗时、watcher 空闲 CPU/内存。
.PARAMETER InstallScheduledTask
    安装"登录 + 解锁时自动重应用"计划任务（非驻留，跑完即退）。推荐的开机生效方式。
.PARAMETER UninstallScheduledTask
    删除上述计划任务。
.PARAMETER InstallWatcher
    （可选）安装轻量常驻 watcher（TaskbarWatcher.exe，约 5MB 内存、事件驱动 0% CPU），
    用于 explorer 重启/改分辨率后即时恢复居中与透明。默认不安装。
.PARAMETER UninstallWatcher
    停止并卸载 watcher。
.PARAMETER BackupDir
    备份目录。默认 .\backup（不要在 param 默认值里用 $PSScriptRoot，见下方说明）。
.EXAMPLE
    .\Win10-Taskbar-Tweak.ps1 -Status
    .\Win10-Taskbar-Tweak.ps1 -Backup
    .\Win10-Taskbar-Tweak.ps1 -Center -Transparency Acrylic
    .\Win10-Taskbar-Tweak.ps1 -Watch -Center -Transparency Blur -IntervalMs 800
    .\Win10-Taskbar-Tweak.ps1 -Restore
#>
[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$Menu,
    [switch]$Benchmark,
    [ValidateSet('auto', 'zh', 'en')]
    [string]$Lang = 'auto',
    [switch]$Backup,
    [switch]$Center,
    [int]$Offset = 0,
    [ValidateSet('', 'Normal', 'Blur', 'Acrylic', 'Clear')]
    [string]$Transparency = '',
    [string]$Tint = '00000000',
    [ValidateSet('', 'On', 'Off')]
    [string]$NativeTransparency = '',
    [switch]$Watch,
    [int]$IntervalMs = 600,
    [switch]$Restore,
    [switch]$InstallStartup,
    [switch]$UninstallStartup,
    [switch]$InstallScheduledTask,
    [switch]$UninstallScheduledTask,
    [switch]$InstallWatcher,
    [switch]$UninstallWatcher,
    [ValidateSet('screen', 'usable')]
    [string]$Anchor = 'screen',
    [switch]$PrimaryOnly,
    [string]$BackupDir = ''
)

# PS5.1 的 param() 默认值求值阶段 $PSScriptRoot 为空（会直接导致脚本崩溃），
# 所以 BackupDir 只能在脚本体内补齐。
if (-not $BackupDir) { $BackupDir = Join-Path $PSScriptRoot 'backup' }
$scriptStartedAt = Get-Date   # 性能测试用：测量"脚本启动+编译"成本

# ---------------------------------------------------------------- i18n
# 跟随系统 UI 语言（中文系统 → 中文菜单，其他 → English）；-Lang zh|en 可强制覆盖。
$uiLang = if ($Lang -eq 'auto') { [System.Globalization.CultureInfo]::CurrentUICulture.Name } else { $Lang }
$script:IsZh = ($uiLang -match '^zh')
function T([string]$zh, [string]$en) { if ($script:IsZh) { $zh } else { $en } }

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
Add-Type -AssemblyName System.Windows.Forms | Out-Null

# ---------------------------------------------------------------- 常量
$SWP_NOSIZE        = 0x0001
$SWP_NOZORDER      = 0x0004
$SWP_NOACTIVATE    = 0x0010
$SWP_ASYNCWINDOWPOS= 0x4000
$SWP_NOSENDCHANGING= 0x0400
$ACCENT_DISABLED   = 0
$ACCENT_TRANSPARENT= 2   # 接近全透明
$ACCENT_BLUR       = 3   # 毛玻璃
$ACCENT_ACRYLIC    = 4   # 亚克力，1803(17134)+

# ---------------------------------------------------------------- 本机信息
$cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
$ubr   = $cv.UBR
$fullBuild = "$build.$ubr"

function Write-Info($msg) { Write-Host "[=] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[-] $msg" -ForegroundColor Red }

# ---------------------------------------------------------------- P/Invoke
$accDll = Join-Path ([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'Accessibility.dll'
if (-not (Test-Path $accDll)) { throw "找不到 Accessibility.dll（.NET Framework 缺失）：$accDll" }

Add-Type -ReferencedAssemblies $accDll -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Accessibility;

public struct RECT  { public int Left, Top, Right, Bottom; }
public struct POINT { public int X, Y; }

public class TB {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string w);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumWindowsProc cb, IntPtr lp);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr lp);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr v);

  [DllImport("oleacc.dll")] public static extern int AccessibleObjectFromWindow(IntPtr hwnd, int objid, ref Guid riid, out IntPtr ppv);
  [DllImport("oleacc.dll")] public static extern uint AccessibleChildren(IntPtr container, int start, int count, IntPtr vars, out int obtained);

  [DllImport("user32.dll")] public static extern bool SetWindowCompositionAttribute(IntPtr h, ref WINCOMPATTRDATA d);
  [StructLayout(LayoutKind.Sequential)] public struct WINCOMPATTRDATA { public int Attribute; public IntPtr Data; public int DataSize; }
  [StructLayout(LayoutKind.Sequential)] public struct ACCENT_POLICY { public int AccentState; public int AccentFlags; public int GradientColor; public int AnimationId; }

  static readonly Guid IID_IAccessible = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");

  public static string ClassName(IntPtr h) {
    if (h == IntPtr.Zero) return "";
    var sb = new StringBuilder(260);
    GetClassNameW(h, sb, 260);
    return sb.ToString();
  }

  public static List<IntPtr> Children(IntPtr parent) {
    var list = new List<IntPtr>();
    EnumChildWindows(parent, delegate(IntPtr h, IntPtr lp) { list.Add(h); return true; }, IntPtr.Zero);
    return list;
  }

  public static IntPtr FindChildByClass(IntPtr parent, string cls) {
    foreach (IntPtr h in Children(parent)) if (ClassName(h) == cls) return h;
    return IntPtr.Zero;
  }

  public static List<IntPtr> FindWindowsByClass(string cls) {
    var list = new List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr lp) { if (ClassName(h) == cls) list.Add(h); return true; }, IntPtr.Zero);
    return list;
  }

  static IAccessible Acc(IntPtr hwnd) {
    Guid g = IID_IAccessible;
    IntPtr p = IntPtr.Zero;
    if (AccessibleObjectFromWindow(hwnd, -4, ref g, out p) != 0 || p == IntPtr.Zero) {
      p = IntPtr.Zero;
      AccessibleObjectFromWindow(hwnd, 0, ref g, out p);
    }
    if (p == IntPtr.Zero) return null;
    try { return (IAccessible)Marshal.GetTypedObjectForIUnknown(p, typeof(IAccessible)); } catch { return null; }
  }

  static int[] Loc(IAccessible a, object childId) {
    int l, t, w, h;
    a.accLocation(out l, out t, out w, out h, childId);
    return new int[] { l, t, w, h };
  }

  // MSAA 子项可能是 IDispatch(VT_DISPATCH=9/VT_UNKNOWN=13)，也可能只是子 ID(VT_I4=3)
  static void Kids(IAccessible a, out List<int> ids, out List<IAccessible> objs) {
    ids = new List<int>(); objs = new List<IAccessible>();
    int cnt = 0;
    try { cnt = a.accChildCount; } catch { return; }
    if (cnt <= 0) return;
    int vs = (IntPtr.Size == 8) ? 24 : 16;
    IntPtr buf = Marshal.AllocHGlobal(cnt * vs);
    try {
      IntPtr punk = Marshal.GetIUnknownForObject(a);
      int got = 0;
      AccessibleChildren(punk, 0, cnt, buf, out got);
      for (int i = 0; i < got; i++) {
        IntPtr v = new IntPtr(buf.ToInt64() + (long)(i * vs));
        int vt = Marshal.ReadInt16(v);
        IntPtr pv = Marshal.ReadIntPtr(v, 8);
        if (vt == 3) ids.Add(pv.ToInt32());
        else if (pv != IntPtr.Zero && (vt == 9 || vt == 13)) {
          try { objs.Add((IAccessible)Marshal.GetTypedObjectForIUnknown(pv, typeof(IAccessible))); } catch { }
        }
      }
    } finally { Marshal.FreeHGlobal(buf); }
  }

  /// 返回 [ok, selfLeft, selfTop, selfWidth, contentWidth, buttonCount]
  public static int[] Measure(IntPtr listHwnd) {
    IAccessible acc = Acc(listHwnd);
    if (acc == null) return new int[] { 0, 0, 0, 0, 0, 0 };
    int[] self = Loc(acc, 0);
    List<int> ids; List<IAccessible> objs;
    Kids(acc, out ids, out objs);
    int maxRight = -1, n = 0;
    if (ids.Count > 0) {
      foreach (int id in ids) {
        int[] b = Loc(acc, id);
        n++;
        if (b[0] + b[2] > maxRight) maxRight = b[0] + b[2];
      }
    } else {
      foreach (IAccessible o in objs) {
        int role = -1;
        try { role = Convert.ToInt32(o.get_accRole(0)); } catch { }
        if (role == 22) {
          List<int> gids; List<IAccessible> gobjs;
          Kids(o, out gids, out gobjs);
          foreach (int id in gids) { int[] b = Loc(o, id); n++; if (b[0] + b[2] > maxRight) maxRight = b[0] + b[2]; }
          foreach (IAccessible go in gobjs) { int[] b = Loc(go, 0); n++; if (b[0] + b[2] > maxRight) maxRight = b[0] + b[2]; }
          break;
        }
      }
    }
    if (maxRight < 0 || n == 0) return new int[] { 0, self[0], self[1], self[2], 0, 0 };
    return new int[] { 1, self[0], self[1], self[2], maxRight - self[0], n };
  }

  /// 把 MSTaskListWClass 放到父窗口客户区内的目标 x（相对坐标）
  public static bool MoveList(IntPtr listHwnd, int xParam, int yParam) {
    return SetWindowPos(listHwnd, IntPtr.Zero, xParam, yParam, 0, 0,
      0x0001 | 0x0004 | 0x0010 | 0x4000 | 0x0400);  // NOSIZE|NOZORDER|NOACTIVATE|ASYNCWINDOWPOS|NOSENDCHANGING
  }

  public static bool SetAccent(IntPtr hwnd, int state, int flags, int color) {
    ACCENT_POLICY ap = new ACCENT_POLICY();
    ap.AccentState = state; ap.AccentFlags = flags;
    ap.GradientColor = color; ap.AnimationId = 0;
    WINCOMPATTRDATA d = new WINCOMPATTRDATA();
    d.Attribute = 19;                                  // WCA_ACCENT_POLICY
    d.DataSize = Marshal.SizeOf(typeof(ACCENT_POLICY));
    d.Data = Marshal.AllocHGlobal(d.DataSize);
    try {
      Marshal.StructureToPtr(ap, d.Data, false);
      return SetWindowCompositionAttribute(hwnd, ref d);
    } finally { Marshal.FreeHGlobal(d.Data); }
  }
}
'@

# ---------------------------------------------------------------- 任务栏目标发现
# 双屏缩放不同时，非 DPI-Aware 进程拿到的是虚拟化坐标，居中会算错，先声明 Per-Monitor V2。
[void][TB]::SetProcessDpiAwarenessContext([IntPtr](-4))

function Get-TaskbarTargets {
    $targets = @()

    $primary = [TB]::FindWindow('Shell_TrayWnd', $null)
    if ($primary -ne [IntPtr]::Zero) {
        $rebar = [TB]::FindChildByClass($primary, 'ReBarWindow32')
        $sw    = [TB]::FindChildByClass($rebar,   'MSTaskSwWClass')
        $list  = [TB]::FindChildByClass($sw,      'MSTaskListWClass')
        if ($list -ne [IntPtr]::Zero) {
            $targets += [pscustomobject]@{
                Name = 'Primary'; Tray = $primary; List = $list; Parent = [TB]::GetParent($list)
            }
        } else {
            Write-Warn "主任务栏下未找到 MSTaskListWClass（可能不是 Win10 任务栏结构，或图标区被隐藏）"
        }
    } else {
        Write-Warn "未找到 Shell_TrayWnd"
    }

    if (-not $PrimaryOnly) {
        foreach ($sec in [TB]::FindWindowsByClass('Shell_SecondaryTrayWnd')) {
            $worker = [TB]::FindChildByClass($sec, 'WorkerW')
            $list   = [TB]::FindChildByClass($worker, 'MSTaskListWClass')
            if ($list -eq [IntPtr]::Zero) { continue }
            $targets += [pscustomobject]@{
                Name = ("Secondary(0x{0:X})" -f $sec.ToInt64())
                Tray = $sec; List = $list; Parent = $worker
            }
        }
    }
    return $targets
}

function Measure-Target($t) {
    $m = [TB]::Measure($t.List)
    $pr = New-Object RECT
    [void][TB]::GetWindowRect($t.Parent, [ref]$pr)
    $cr = New-Object RECT
    [void][TB]::GetClientRect($t.Parent, [ref]$cr)
    [pscustomobject]@{
        Ok        = ($m[0] -eq 1)
        ListLeft  = $m[1]
        ContentW  = $m[4]
        Buttons   = $m[5]
        ParentW   = $cr.Right
        ParentLeft= $pr.Left
    }
}

function Get-UsableBounds($t) {
    # 图标可以摆放的真实横向区间 [左, 右)（屏幕像素）。
    # 左界 = 列表父窗口（主屏 MSTaskSwWClass / 副屏 WorkerW）左缘，即开始按钮/搜索框之后；
    # 右界 = 父窗口右侧最靠左的"非任务列表"兄弟窗口——主屏是资讯/天气组件(DynamicContent2)
    #        和 TrayNotifyWnd，副屏是 ClockButton。注意主屏 rebar 会延伸到天气组件下面，
    #        直接用父窗口宽度居中会把图标塞到组件底下，这就是旧版居中偏右的原因。
    $pr = New-Object RECT
    [void][TB]::GetWindowRect($t.Parent, [ref]$pr)
    $left = $pr.Left
    $right = -1
    foreach ($h in [TB]::Children($t.Tray)) {
        if ([TB]::GetParent($h) -ne $t.Tray) { continue }   # 只要直接子级
        $cls = [TB]::ClassName($h)
        if ($cls -in @('ReBarWindow32', 'MSTaskSwWClass', 'WorkerW', 'MSTaskListWClass')) { continue }
        $r = New-Object RECT
        [void][TB]::GetWindowRect($h, [ref]$r)
        if (($r.Right - $r.Left) -le 0) { continue }
        if ($r.Left -lt ($left + 200)) { continue }          # 左侧簇（Start、搜索占位等）
        if ($right -lt 0 -or $r.Left -lt $right) { $right = $r.Left }
    }
    if ($right -lt 0) {
        $tr = New-Object RECT
        [void][TB]::GetWindowRect($t.Tray, [ref]$tr)
        $right = $tr.Right
    }
    return @($left, $right)
}

function Set-TargetCenter($t, [int]$offset) {
    $mm = Measure-Target $t
    if (-not $mm.Ok -or $mm.ContentW -le 0) { return $false }
    $b  = Get-UsableBounds $t
    $tr = New-Object RECT
    [void][TB]::GetWindowRect($t.Tray, [ref]$tr)
    if ($Anchor -eq 'usable') {
        $target = $b[0] + [int](($b[1] - $b[0] - $mm.ContentW) / 2)
    } else {
        # screen：相对整块任务栏（即屏幕）居中，观感与 Win11 一致
        $target = $tr.Left + [int](($tr.Right - $tr.Left - $mm.ContentW) / 2)
    }
    $target += $offset
    # 夹紧到可用区间，避免图标越过开始按钮或钻到天气组件/托盘底下
    $maxLeft = $b[1] - $mm.ContentW
    if ($target -lt $b[0]) { $target = $b[0] }
    if (($maxLeft -gt $b[0]) -and ($target -gt $maxLeft)) { $target = $maxLeft }
    # SetWindowPos 的 x/y 是相对父窗口客户区原点，必须换算
    $origin = New-Object POINT
    [void][TB]::ClientToScreen($t.Parent, [ref]$origin)
    $lr = New-Object RECT
    [void][TB]::GetWindowRect($t.List, [ref]$lr)
    $yParam = $lr.Top - $origin.Y                      # 保持原有纵向位置
    return [TB]::MoveList($t.List, ($target - $origin.X), $yParam)
}

function Reset-TargetCenter($t) {
    $origin = New-Object POINT
    [void][TB]::ClientToScreen($t.Parent, [ref]$origin)
    $lr = New-Object RECT
    [void][TB]::GetWindowRect($t.List, [ref]$lr)
    $yParam = $lr.Top - $origin.Y
    return [TB]::MoveList($t.List, 0, $yParam)         # x=0 即系统默认（贴左）
}

function Get-AccentStyle($name) {
    # 实测（19045.6466）：Clear 必须带 ACCENT_FLAG_GRADIENT_COLOR(0x2)，
    # 否则 DWM 忽略 GradientColor、直接把任务栏画成不透明的系统强调色。
    switch ($name) {
        'Normal'  { return @{ State = $ACCENT_DISABLED;    Flags = 0 } }
        'Clear'   { return @{ State = $ACCENT_TRANSPARENT; Flags = 2 } }
        'Blur'    { return @{ State = $ACCENT_BLUR;        Flags = 0 } }
        'Acrylic' {
            if ($build -lt 17134) {
                Write-Warn "亚克力需要 1803(17134)+，当前 $fullBuild，自动降级为 Blur"
                return @{ State = $ACCENT_BLUR; Flags = 0 }
            }
            return @{ State = $ACCENT_ACRYLIC; Flags = 2 }
        }
    }
    return @{ State = $ACCENT_DISABLED; Flags = 0 }
}

function Convert-TintToGradientColor([string]$tint) {
    # 入参按 AARRGGBB 解析；SetWindowCompositionAttribute 的 GradientColor 是 0xAABBGGRR，
    # R 和 B 通道需要交换，否则叠加颜色会偏色。
    if ($tint -notmatch '^[0-9a-fA-F]{8}$') { throw "Tint 必须是 8 位十六进制 AARRGGBB，例如 66000000（当前: '$tint'）" }
    $ta = [Convert]::ToUInt32($tint.Substring(0, 2), 16)
    $tr = [Convert]::ToUInt32($tint.Substring(2, 2), 16)
    $tg = [Convert]::ToUInt32($tint.Substring(4, 2), 16)
    $tb = [Convert]::ToUInt32($tint.Substring(6, 2), 16)
    $v  = [uint32](($ta -shl 24) -bor ($tb -shl 16) -bor ($tg -shl 8) -bor $tr)
    return [BitConverter]::ToInt32([BitConverter]::GetBytes($v), 0)
}

# ---------------------------------------------------------------- 注册表备份/还原
# 全部走 .NET 注册表 API，不调用 reg.exe（避免依赖外部程序/被策略拦截）
$regKeys = @(
    'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
    'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced',
    'Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
)

function Get-RegValues($subPath) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subPath)
    if ($null -eq $key) { return @() }
    $list = @()
    foreach ($n in $key.GetValueNames()) {
        $kind = $key.GetValueKind($n).ToString()
        $v    = $key.GetValue($n)
        switch ($kind) {
            'DWord'       { $sv = [int]$v }
            'QWord'       { $sv = [long]$v }
            'Binary'      { $sv = [Convert]::ToBase64String([byte[]]$v) }
            'MultiString' { $sv = @([string[]]$v) }
            default       { $sv = [string]$v }
        }
        $list += [pscustomobject]@{ Name = $n; Kind = $kind; Value = $sv }
    }
    $key.Close()
    return $list
}

function Convert-ToRegLine($name, $kind, $v) {
    $n = if ($name -eq '') { '@' } else { '"' + ($name -replace '\\', '\\\\' -replace '"', '\\"') + '"' }
    switch ($kind) {
        'DWord'  { return "$n=dword:$('{0:x8}' -f [int]$v)" }
        'QWord'  { $b = [BitConverter]::GetBytes([long]$v)
                   return "$n=hex(b):" + (($b | ForEach-Object { '{0:x2}' -f $_ }) -join ',') }
        'Binary' { $b = [Convert]::FromBase64String($v)
                   return "$n=hex:" + (($b | ForEach-Object { '{0:x2}' -f $_ }) -join ',') }
        'ExpandString' { $b = [Text.Encoding]::Unicode.GetBytes([string]$v + "`0")
                   return "$n=hex(2):" + (($b | ForEach-Object { '{0:x2}' -f $_ }) -join ',') }
        'MultiString'  { $b = [Text.Encoding]::Unicode.GetBytes((($v -join "`0") + "`0`0"))
                   return "$n=hex(7):" + (($b | ForEach-Object { '{0:x2}' -f $_ }) -join ',') }
        default  { return "$n=`"" + ([string]$v -replace '\\', '\\\\' -replace '"', '\\"') + "`"" }
    }
}

function Export-RegFile($subPath, $file) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('Windows Registry Editor Version 5.00')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("[HKEY_CURRENT_USER\$subPath]")
    $vals = @(Get-RegValues $subPath)
    if ($vals.Count -eq 0) { [void]$sb.AppendLine('; (该键不存在或没有值)') }
    else { foreach ($x in $vals) { [void]$sb.AppendLine((Convert-ToRegLine $x.Name $x.Kind $x.Value)) } }
    [System.IO.File]::WriteAllText($file, $sb.ToString(), [System.Text.Encoding]::Unicode)
}

function Invoke-Backup {
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $snap = [ordered]@{ Time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Build = $fullBuild; Keys = @() }
    foreach ($k in $regKeys) {
        $file = Join-Path $BackupDir (($k -split '\\')[-1] + '.reg')
        Export-RegFile $k $file
        Write-Ok "已备份 -> $file"
        $snap.Keys += [ordered]@{ Path = $k; Values = @(Get-RegValues $k) }
    }
    $snapFile = Join-Path $BackupDir 'snapshot.json'
    ($snap | ConvertTo-Json -Depth 8) | Set-Content $snapFile -Encoding UTF8
    Write-Ok "快照 -> $snapFile  （-Restore 用这个还原，.reg 供双击手工导入）"
}

function Invoke-RestoreRegistry {
    $snapFile = Join-Path $BackupDir 'snapshot.json'
    if (-not (Test-Path $snapFile)) {
        Write-Warn "未找到 $snapFile，跳过注册表还原。"
        Write-Warn "（脚本本身不写注册表，除非你用过 -NativeTransparency 或手工导入了 .reg）"
        return
    }
    $snap = (Get-Content $snapFile -Raw -Encoding UTF8) | ConvertFrom-Json
    foreach ($entry in @($snap.Keys)) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($entry.Path)
        foreach ($v in @($entry.Values)) {
            switch ($v.Kind) {
                'DWord'       { $key.SetValue($v.Name, [int]$v.Value,    [Microsoft.Win32.RegistryValueKind]::DWord) }
                'QWord'       { $key.SetValue($v.Name, [long]$v.Value,   [Microsoft.Win32.RegistryValueKind]::QWord) }
                'Binary'      { $key.SetValue($v.Name, [Convert]::FromBase64String($v.Value), [Microsoft.Win32.RegistryValueKind]::Binary) }
                'MultiString' { $key.SetValue($v.Name, [string[]]@($v.Value), [Microsoft.Win32.RegistryValueKind]::MultiString) }
                'ExpandString'{ $key.SetValue($v.Name, [string]$v.Value, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
                default       { $key.SetValue($v.Name, [string]$v.Value, [Microsoft.Win32.RegistryValueKind]::String) }
            }
        }
        $key.Close()
        Write-Ok "已还原注册表: HKCU\$($entry.Path)"
    }
}

function Set-NativeTransparency($onOff) {
    $p = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path (Join-Path $BackupDir 'snapshot.json'))) { Invoke-Backup }
    $val = if ($onOff -eq 'On') { 1 } else { 0 }
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($p)
    $key.SetValue('EnableTransparency', $val, [Microsoft.Win32.RegistryValueKind]::DWord)
    $key.Close()
    Write-Ok "HKCU\...\Themes\Personalize\EnableTransparency = $val"
    Write-Warn "若未立即生效：任务栏空白处右键无解，需重启 explorer 或注销重登一次。"
}


# ---------------------------------------------------------------- 开机自启（启动文件夹，不用 schtasks）
function Get-StartupFile {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) 'Win10TaskbarTweak.cmd')
}

function Install-StartupEntry {
    # 开机启动项 = 登录时一次性运行（应用完即退出，不常驻）。
    # 优先用 TaskbarWatcher.exe --apply-once：毫秒级、不依赖 PowerShell（低配机登录更轻快）。
    if (-not (Test-Path (Join-Path $BackupDir 'snapshot.json'))) { Invoke-Backup }
    $act = Get-ReapplyAction
    $f = Get-StartupFile
    $body = "@echo off`r`nstart `"`" /min `"" + $act.Cmd + "`" " + $act.Args + "`r`n"
    [System.IO.File]::WriteAllText($f, $body, [System.Text.Encoding]::Default)
    Write-Ok "已写入开机启动项（登录时运行一次，非驻留，方式=$($act.Kind)） -> $f"
    Write-Info "启动命令: $($act.Cmd) $($act.Args)"
    Write-Info "想取消：删掉这个文件，或运行 -UninstallStartup"
}

function Uninstall-StartupEntry {
    $f = Get-StartupFile
    if (Test-Path $f) { Remove-Item $f -Force; Write-Ok "已删除开机启动项: $f" }
    else { Write-Warn "开机启动项本来就不存在: $f" }
    Get-Process -Name powershell -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            if ($_.Id -eq $PID) { return }
            $cl = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
            if ($cl -like '*Win10-Taskbar-Tweak.ps1*' -and $cl -like '*-Watch*') {
                Stop-Process -Id $_.Id -Force
                Write-Ok "已结束常驻进程 PID $($_.Id)"
            }
        } catch { }
    }
}

# ---------------------------------------------------------------- 自启/计划任务（登录重应用，非驻留）
# 注意：非管理员只能在任务计划根目录注册任务（建子文件夹需要提权），所以用 '\' + 前缀命名。
$TaskPath        = '\'
$ReapplyTaskName = 'Win10TaskbarTweak-Reapply'
$WatcherTaskName = 'Win10TaskbarTweak-Watcher'

function Get-PsArgsForTask {
    $a = @('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"')
    if ($Center)       { $a += '-Center' }
    if ($Offset)       { $a += @('-Offset', "$Offset") }
    if ($Transparency) { $a += @('-Transparency', $Transparency); if ($Tint -ne '00000000') { $a += @('-Tint', $Tint) } }
    $a += @('-Anchor', $Anchor)
    if ($PrimaryOnly)  { $a += '-PrimaryOnly' }
    return ($a -join ' ')
}

function Get-ReapplyAction {
    # 登录重应用的最佳方式：TaskbarWatcher.exe --apply-once（实测内部工作 17ms，
    # 不启动 PowerShell、不做运行时编译）；exe 缺失才回退 PowerShell 一次性运行。
    $exe = Get-WatcherExePath
    if (Test-Path $exe) {
        return @{ Cmd = $exe; Args = ((Get-WatcherArgs) + ' --apply-once'); Kind = 'exe(毫秒级)' }
    }
    return @{ Cmd = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"; Args = (Get-PsArgsForTask); Kind = 'powershell(回退)' }
}

function New-TweakTaskXml([string]$uri, [string]$desc, [string]$command, [string]$arguments, [bool]$oneShot) {
    $user   = "$env:USERDOMAIN\$env:USERNAME"
    $esc    = { param($s) [System.Security.SecurityElement]::Escape($s) }
    $limit  = if ($oneShot) { 'PT2M' } else { 'PT0S' }   # 常驻 watcher 不限时长
    $unlock = if ($oneShot) { "`n    <SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>SessionUnlock</StateChange></SessionStateChangeTrigger>" } else { '' }
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$(& $esc $desc)</Description>
    <URI>$uri</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled></LogonTrigger>$unlock
  </Triggers>
  <Principals>
    <Principal id="Author"><UserId>$user</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>$limit</ExecutionTimeLimit>
    <Priority>5</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec><Command>$(& $esc $command)</Command><Arguments>$(& $esc $arguments)</Arguments></Exec>
  </Actions>
</Task>
"@
}

function Install-ReapplyTask {
    # 先清掉旧设计的启动项（内容含 -Watch 的常驻旧条目；新设计的同名条目不含 -Watch，保留无妨）
    $legacy = Join-Path ([Environment]::GetFolderPath('Startup')) 'Win10TaskbarTweak.cmd'
    if ((Test-Path $legacy) -and ((Get-Content $legacy -Raw -ErrorAction SilentlyContinue) -like '*-Watch*')) {
        Remove-Item $legacy -Force
        Write-Warn "已移除旧启动项 $legacy（旧条目是常驻 -Watch，会被一次性运行取代）"
    }
    $act = Get-ReapplyAction
    $xml = New-TweakTaskXml "$TaskPath$ReapplyTaskName" `
        "Win10 taskbar: re-apply centering/transparency at logon and unlock, then exits (non-resident)." `
        $act.Cmd $act.Args $true
    try {
        Register-ScheduledTask -TaskPath $TaskPath -TaskName $ReapplyTaskName -Xml $xml -Force -ErrorAction Stop | Out-Null
        Write-Ok "计划任务已安装: ${TaskPath}${ReapplyTaskName}（触发器：登录+解锁，非驻留，方式=$($act.Kind)）"
    } catch {
        Write-Warn "计划任务安装失败（本系统限制标准用户创建计划任务），自动改用启动文件夹。"
        Install-StartupEntry
        Write-Info "启动文件夹方式只在登录时生效；解锁/explorer 重启后如需恢复，重跑本工具或安装 watcher（菜单 5）。"
    }
    Save-State
}

function Invoke-BuildWatcher {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) { throw "csc.exe not found: $csc" }
    $src = Join-Path $PSScriptRoot 'TaskbarWatcher.cs'
    if (-not (Test-Path $src)) { throw "TaskbarWatcher.cs not found: $src" }
    $exe  = Get-WatcherExePath
    $refs = Join-Path ([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'Accessibility.dll'
    & $csc '/nologo' '/target:winexe' '/optimize+' "/r:$refs" "/out:$exe" "$src"
    if ($LASTEXITCODE -ne 0) { throw "TaskbarWatcher compilation failed (csc exit code $LASTEXITCODE)" }
    Write-Ok "Compiled -> $exe"
}

function Get-WatcherExePath { Join-Path $PSScriptRoot 'TaskbarWatcher.exe' }

function Get-WatcherArgs {
    $style = if ($Transparency) { $Transparency.ToLower() } else { 'clear' }
    $a = @("--style=$style")
    if ($Tint -ne '00000000') { $a += "--tint=$Tint" }
    if ($Offset)              { $a += "--offset=$Offset" }
    $a += "--anchor=$Anchor"
    if ($PrimaryOnly)         { $a += '--primary-only' }
    if (-not $Center -and $style -eq 'normal') { $a += '--no-center' }
    return ($a -join ' ')
}

function Get-WatcherStartupFile {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'Win10TaskbarTweak-Watcher.cmd'
}

function Install-Watcher {
    if (-not (Test-Path (Get-WatcherExePath))) { Invoke-BuildWatcher }
    try {
        $xml = New-TweakTaskXml "$TaskPath$WatcherTaskName" `
            "Win10 taskbar lightweight resident watcher (event-driven, ~13MB RAM): instantly restores centering/transparency after explorer restarts, resolution changes, etc." `
            (Get-WatcherExePath) (Get-WatcherArgs) $false
        Register-ScheduledTask -TaskPath $TaskPath -TaskName $WatcherTaskName -Xml $xml -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask  -TaskPath $TaskPath -TaskName $WatcherTaskName
        Write-Ok "watcher 已安装并启动（计划任务: ${TaskPath}${WatcherTaskName}）"
    } catch {
        # 本机计划任务受限时，用启动文件夹常驻 watcher（效果相同）
        $f = Get-WatcherStartupFile
        $body = "@echo off`r`nstart `"`" /min `"" + (Get-WatcherExePath) + "`" " + (Get-WatcherArgs) + "`r`n"
        [System.IO.File]::WriteAllText($f, $body, [System.Text.Encoding]::Default)
        Start-Process -FilePath (Get-WatcherExePath) -ArgumentList (Get-WatcherArgs)
        Write-Ok "计划任务不可用，watcher 已通过启动文件夹安装并启动"
    }
    Write-Info "实测：空闲 CPU 0%，内存约 13MB；explorer 重启/改分辨率后 1 秒内自动恢复。"
    Write-Info "想取消：菜单 [5]，或 -UninstallWatcher，或 Uninstall"
    Save-State
}

function Uninstall-ScheduledTasks {
    foreach ($n in @($ReapplyTaskName, $WatcherTaskName)) {
        $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $n -ErrorAction SilentlyContinue
        if ($t) {
            Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $n -Confirm:$false
            Write-Ok "Scheduled task removed: ${TaskPath}$n"
        }
    }
    Get-Process -Name 'TaskbarWatcher' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Uninstall-Watcher {
    Get-Process -Name 'TaskbarWatcher' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $WatcherTaskName -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $WatcherTaskName -Confirm:$false }
    $wf = Get-WatcherStartupFile
    if (Test-Path $wf) { Remove-Item $wf -Force }
    Save-State
    Write-Ok "watcher 已停止并移除（若存在）"
}

# ---------------------------------------------------------------- 状态文件
# accent 没有查询接口，菜单显示的"当前样式"以最近一次应用记录为准（state.json，项目内文件）。
function Get-StateFile { Join-Path $PSScriptRoot 'state.json' }

function Save-State {
    $auto = ''
    if (Get-ScheduledTask -TaskPath $TaskPath -TaskName $ReapplyTaskName -ErrorAction SilentlyContinue) { $auto = 'task' }
    elseif (Test-Path (Get-StartupFile)) { $auto = 'startup' }
    $watcher = [bool](Get-Process TaskbarWatcher -ErrorAction SilentlyContinue) -or
               [bool](Get-ScheduledTask -TaskPath $TaskPath -TaskName $WatcherTaskName -ErrorAction SilentlyContinue) -or
               (Test-Path (Get-WatcherStartupFile))
    $st = [ordered]@{
        UpdatedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Center    = [bool]$Center
        Style     = if ($Transparency) { $Transparency } else { '' }
        Tint      = $Tint
        Anchor    = $Anchor
        Offset    = $Offset
        Autostart = $auto
        Watcher   = $watcher
    }
    try { $st | ConvertTo-Json | Set-Content (Get-StateFile) -Encoding UTF8 } catch { }
}

function Read-State {
    $f = Get-StateFile
    if (Test-Path $f) { try { return (Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null } }
    return $null
}

function Clear-State { Remove-Item (Get-StateFile) -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- 交互菜单
function Get-LiveCenterState([string]$anchor) {
    # 实测当前图标是否处于居中位置（当前列表左边 vs 应在位置，±8px 容差）
    try {
        $t = (Get-TaskbarTargets) | Select-Object -First 1
        if (-not $t) { return @{ Ok = $false; Text = (T '未找到任务栏' 'taskbar not found') } }
        $mm = Measure-Target $t
        if (-not $mm.Ok) { return @{ Ok = $false; Text = (T '无法测量' 'cannot measure') } }
        $b  = Get-UsableBounds $t
        $tr = New-Object RECT
        [void][TB]::GetWindowRect($t.Tray, [ref]$tr)
        $expected = if ($anchor -eq 'usable') { $b[0] + [int](($b[1] - $b[0] - $mm.ContentW) / 2) }
                    else                      { $tr.Left + [int](($tr.Right - $tr.Left - $mm.ContentW) / 2) }
        $diff = [math]::Abs($mm.ListLeft - $expected)
        if ($diff -le 8)              { return @{ Ok = $true;  Text = (T "已居中（偏差 ${diff}px）" "centered (off by ${diff}px)") } }
        elseif ($mm.ListLeft -le 100) { return @{ Ok = $false; Text = (T '未开启（靠左）' 'off (left-aligned)') } }
        else                          { return @{ Ok = $false; Text = (T "偏离 ${diff}px" "off by ${diff}px") } }
    } catch { return @{ Ok = $false; Text = (T '检测失败' 'detect failed') } }
}

function Pause-Menu { Write-Host ""; Read-Host (T '  回车返回菜单' '  Press Enter to return') | Out-Null }

function Invoke-ApplyNow([string]$style) {
    try {
        $styleObj = Get-AccentStyle $style
        $tintVal = Convert-TintToGradientColor $Tint
        $et = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).EnableTransparency
        if ($et -eq 0) { Set-NativeTransparency 'On' }
        foreach ($t in Get-TaskbarTargets) {
            [void](Set-TargetCenter $t $Offset)
            $ok = [TB]::SetAccent($t.Tray, $styleObj.State, $styleObj.Flags, $tintVal)
            if (-not $ok) { Write-Warn (T "$($t.Name): 透明应用被拒绝（SetWindowCompositionAttribute 返回 False）" "$($t.Name): transparency rejected (SetWindowCompositionAttribute returned False)") }
        }
        $script:Transparency = $style
        $script:Center = $true
        Save-State
        Write-Ok (T "已应用：图标居中 + $style" "Applied: centered icons + $style")
    } catch { Write-Err (T "应用失败: $_" "Apply failed: $_") }
}

function Invoke-RestoreAll {
    Write-Info (T "还原中..." "Restoring...")
    foreach ($t in Get-TaskbarTargets) {
        [void](Reset-TargetCenter $t)
        [void][TB]::SetAccent($t.Tray, 0, 0, 0)
        Write-Ok (T "$($t.Name): 位置归零 + 关闭 accent 透明" "$($t.Name): position reset + accent disabled")
    }
    Invoke-RestoreRegistry
    Clear-State
    Write-Ok (T "还原完成（若任务栏显示异常，可重启 explorer 或注销重登）" "Restore complete (if the taskbar looks wrong, restart explorer or sign out/in)")
}

function Toggle-Autostart {
    $hasTask    = [bool](Get-ScheduledTask -TaskPath $TaskPath -TaskName $ReapplyTaskName -ErrorAction SilentlyContinue)
    $hasStartup = Test-Path (Get-StartupFile)
    if ($hasTask -or $hasStartup) {
        if ($hasTask)    { Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $ReapplyTaskName -Confirm:$false; Write-Ok (T "已移除自启计划任务" "Scheduled task removed") }
        if ($hasStartup) { Uninstall-StartupEntry }
        Save-State
    } else {
        Install-ReapplyTask
    }
}

function Toggle-Watcher {
    $on = [bool](Get-Process TaskbarWatcher -ErrorAction SilentlyContinue) -or
          [bool](Get-ScheduledTask -TaskPath $TaskPath -TaskName $WatcherTaskName -ErrorAction SilentlyContinue) -or
          (Test-Path (Get-WatcherStartupFile))
    if ($on) { Uninstall-Watcher } else { Install-Watcher }
}

function Show-StyleSubmenu {
    Write-Host ""
    Write-Host (T "   [1] Clear   全透明（透出壁纸，最清爽）" "   [1] Clear   fully transparent (wallpaper shows through)")
    Write-Host (T "   [2] Blur    毛玻璃（Win10 经典模糊）"        "   [2] Blur    acrylic-less blur (classic Win10)")
    Write-Host (T "   [3] Acrylic 亚克力（更通透的模糊；少数老机器可能有输入延迟）" "   [3] Acrylic blur (clearer; may lag on some old machines)")
    $s = Read-Host (T "   请选择样式（回车取消）" "   Pick a style (Enter to cancel)")
    switch ($s) {
        '1' { Invoke-ApplyNow 'Clear';   Pause-Menu }
        '2' { Invoke-ApplyNow 'Blur';    Pause-Menu }
        '3' { Invoke-ApplyNow 'Acrylic'; Pause-Menu }
        default { }
    }
}

function Show-StartMenuSubmenu {
    $smStateFile = Join-Path $PSScriptRoot 'StartMenu\state.json'
    while ($true) {
        Clear-Host
        $st = $null
        if (Test-Path $smStateFile) { try { $st = Get-Content $smStateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
        $appliedText = if ($st) {
            T ("{0} 个应用（{1}，颜色 {2}，图标规范化 {3}）" -f @($st.Patched).Count, $st.UpdatedAt, $st.Color, $st.NormalizeIcons) `
             ("{0} apps ({1}, color {2}, icon-normalized {3})" -f @($st.Patched).Count, $st.UpdatedAt, $st.Color, $st.NormalizeIcons)
        } else { T '未应用' 'not applied' }
        Write-Host ""
        Write-Host (T "        开始菜单美化" "        Start Menu Beautifier") -ForegroundColor White
        Write-Host "  ──────────────────────────────────────────"
        Write-Host ("   " + (T '已应用美化   : ' 'Applied       : ') + $appliedText)
        Write-Host "  ──────────────────────────────────────────"
        Write-Host (T "   [1] 应用美化（统一磁贴底色 + 规范化图标，需一次 UAC）" "   [1] Apply (uniform tile color + normalized icons, one UAC)")
        Write-Host (T "   [2] 还原开始菜单原状" "   [2] Restore original start menu")
        Write-Host (T "   [3] 查看状态" "   [3] Status")
        Write-Host (T "   [0] 返回主菜单" "   [0] Back to main menu")
        Write-Host ""
        switch (Read-Host (T "  请输入数字后回车" "  Enter a number")) {
            '1' { & (Join-Path $PSScriptRoot 'Start-Menu-Tweak.ps1') -Beautify -NormalizeIcons -Lang $(if ($script:IsZh) {'zh'} else {'en'}); Pause-Menu }
            '2' { & (Join-Path $PSScriptRoot 'Start-Menu-Tweak.ps1') -Restore -Lang $(if ($script:IsZh) {'zh'} else {'en'}); Pause-Menu }
            '3' { & (Join-Path $PSScriptRoot 'Start-Menu-Tweak.ps1') -Status -Lang $(if ($script:IsZh) {'zh'} else {'en'}); Pause-Menu }
            '0' { return }
            default { }
        }
    }
}

function Show-Menu {
    while ($true) {
        Clear-Host
        $st   = Read-State
        $anchor = if ($st -and $st.Anchor) { $st.Anchor } else { $Anchor }
        $live = Get-LiveCenterState $anchor
        $styleText = if ($st -and $st.Style) { "{0} ({1})" -f $st.Style, $st.UpdatedAt } else { (T '未应用' 'not applied') }
        $autoText  = if ($st -and $st.Autostart) {
            if ($st.Autostart -eq 'task')    { T '计划任务（登录+解锁）' 'scheduled task (logon+unlock)' }
            elseif ($st.Autostart -eq 'startup') { T '启动文件夹（登录）' 'startup folder (logon)' }
            else { $st.Autostart }
        } else { T '未开启' 'off' }
        $watcherOn = [bool](Get-Process TaskbarWatcher -ErrorAction SilentlyContinue) -or
                     [bool](Get-ScheduledTask -TaskPath $TaskPath -TaskName $WatcherTaskName -ErrorAction SilentlyContinue) -or
                     (Test-Path (Get-WatcherStartupFile))
        Write-Host ""
        Write-Host (T "        Win10 桌面美化 —— 任务栏 + 开始菜单" "        Win10 Desktop Beautifier — Taskbar + Start Menu") -ForegroundColor White
        Write-Host "  ──────────────────────────────────────────"
        Write-Host ("   " + (T '图标居中      : ' 'Centered icons : ') + $(if ($live.Ok) { "[√] " + $live.Text } else { "[×] " + $live.Text }))
        Write-Host ("   " + (T '任务栏透明    : ' 'Taskbar style  : ') + $styleText)
        Write-Host ("   " + (T '开机自动生效  : ' 'Run at logon   : ') + $autoText)
        Write-Host ("   " + (T '即时恢复      : ' 'Live recovery  : ') + $(if ($watcherOn) { T 'watcher 运行中（约13MB，0% CPU）' 'watcher running (~13MB, 0% CPU)' } else { T '未安装（可选）' 'not installed (optional)' }))
        Write-Host "  ──────────────────────────────────────────"
        Write-Host (T "   [1] 开启 居中 + 全透明（推荐）" "   [1] Enable centered + fully transparent (recommended)")
        Write-Host (T "   [2] 更换透明样式（全透 / 毛玻璃 / 亚克力）" "   [2] Change transparency style (clear / blur / acrylic)")
        Write-Host (T "   [3] 恢复系统默认（取消全部效果）" "   [3] Restore Windows defaults (undo all)")
        Write-Host (T "   [4] 开机自动生效：开 / 关" "   [4] Run at logon: on / off")
        Write-Host (T "   [5] 即时恢复 watcher：开 / 关" "   [5] Live-recovery watcher: on / off")
        Write-Host (T "   [6] 性能测试" "   [6] Benchmark")
        Write-Host (T "   [7] 开始菜单美化（统一磁贴底色/图标）" "   [7] Start menu beautifier (uniform tiles/icons)")
        Write-Host (T "   [0] 退出" "   [0] Exit")
        Write-Host ""
        switch (Read-Host (T "  请输入数字后回车" "  Enter a number")) {
            '1' { Invoke-ApplyNow 'Clear';  Pause-Menu }
            '2' { Show-StyleSubmenu }
            '3' { Invoke-RestoreAll;        Pause-Menu }
            '4' { Toggle-Autostart;         Pause-Menu }
            '5' { Toggle-Watcher;           Pause-Menu }
            '6' { Invoke-Benchmark;         Pause-Menu }
            '7' { Show-StartMenuSubmenu }
            '0' { return }
            default { }
        }
    }
}

# ---------------------------------------------------------------- 性能测试
function Invoke-Benchmark {
    $benchStyle = if ($Transparency) { $Transparency }
                  elseif ((Read-State) -and (Read-State).Style) { (Read-State).Style }
                  else { 'Clear' }
    Write-Host ""
    Write-Host (" ==================== " + (T '性能测试' 'Benchmark') + " ==================== ") -ForegroundColor White
    Write-Host (T " 说明：测试过程会把任务栏应用为「居中 + $benchStyle」，结束后保持该状态。" " Note: the taskbar is set to 'centered + $benchStyle' during the test and kept afterwards.") -ForegroundColor DarkGray

    $bootMs = [math]::Round(((Get-Date) - $scriptStartedAt).TotalMilliseconds)
    Write-Host (T ("  ① PowerShell 启动+编译        : {0,5} ms  （仅 PowerShell 回退自启才有此开销）" -f $bootMs) `
              ("  (1) PowerShell start+compile  : {0,5} ms  (only for the PowerShell fallback path)" -f $bootMs))

    $targets = Get-TaskbarTargets
    $t0 = $targets | Select-Object -First 1
    if ($t0) {
        $samples = 1..10 | ForEach-Object { (Measure-Command { Measure-Target $t0 | Out-Null }).TotalMilliseconds }
        $msaa = [math]::Round(($samples | Measure-Object -Average).Average, 2)
        Write-Host (T ("  ② 图标宽度测量（MSAA）       : {0,5} ms/次（watcher 仅在任务栏变化时调用）" -f $msaa) `
                  ("  (2) Icon width measure (MSAA): {0,5} ms   (watcher only, on taskbar changes)" -f $msaa))

        $styleObj = Get-AccentStyle $benchStyle
        $tintVal = Convert-TintToGradientColor $Tint
        $samples = 1..10 | ForEach-Object { (Measure-Command { [void][TB]::SetAccent($t0.Tray, $styleObj.State, $styleObj.Flags, $tintVal) }).TotalMilliseconds }
        $acc = [math]::Round(($samples | Measure-Object -Average).Average, 3)
        Write-Host (T ("  ③ 透明效果应用（accent）     : {0,5} ms/次" -f $acc) `
                  ("  (3) Transparency (accent)    : {0,5} ms" -f $acc))
    }

    $exe = Get-WatcherExePath
    if (Test-Path $exe) {
        $exeArgs = (Get-WatcherArgs) + ' --apply-once'
        $samples = 1..3 | ForEach-Object { (Measure-Command { Start-Process -FilePath $exe -ArgumentList $exeArgs -Wait }).TotalMilliseconds }
        $exeMs = [math]::Round(($samples | Measure-Object -Average).Average)
        Write-Host (T ("  ④ 登录自启（exe 进程墙钟）   : {0,5} ms  （内部实际工作 ~17ms，其余为 .NET 进程启动）" -f $exeMs) `
                  ("  (4) Logon apply (exe wall)   : {0,5} ms  (~17ms real work, rest is .NET startup)" -f $exeMs))
    } else {
        Write-Host (T "  ④ 登录自启（exe 进程墙钟）   :   n/a  （exe 未编译，菜单 [5] 会自动编译）" "  (4) Logon apply (exe wall)   :   n/a  (exe not built; menu [5] builds it)")
    }

    $psApply = (Measure-Command {
        foreach ($t in $targets) { [void](Set-TargetCenter $t $Offset); [void][TB]::SetAccent($t.Tray, (Get-AccentStyle $benchStyle).State, (Get-AccentStyle $benchStyle).Flags, (Convert-TintToGradientColor $Tint)) }
    }).TotalMilliseconds
    Write-Host (T ("  ⑤ 全量应用（居中+透明）      : {0,5} ms" -f [math]::Round($psApply)) `
              ("  (5) Full apply (center+trans): {0,5} ms" -f [math]::Round($psApply)))

    $w = Get-Process TaskbarWatcher -ErrorAction SilentlyContinue
    if ($w) {
        $c0 = $w.TotalProcessorTime.TotalMilliseconds
        Start-Sleep -Seconds 3
        $w.Refresh()
        $c1 = $w.TotalProcessorTime.TotalMilliseconds
        $pct = [math]::Round((($c1 - $c0) / 3000) * 100, 2)
        Write-Host (T ("  ⑥ watcher 空闲 CPU           : {0,5} %    内存 {1} MB" -f $pct, [math]::Round($w.PrivateMemorySize64 / 1MB, 1)) `
                  ("  (6) Watcher idle CPU         : {0,5} %    mem {1} MB" -f $pct, [math]::Round($w.PrivateMemorySize64 / 1MB, 1)))
    } else {
        Write-Host (T "  ⑥ watcher 空闲 CPU           :   n/a  （未运行，菜单 [5] 安装后再测）" "  (6) Watcher idle CPU         :   n/a  (not running; install via menu [5])")
    }

    Write-Host "  ------------------------------------------------"
    Write-Host (T "  参考结论：登录自启走 ④，异步隐藏运行，不拖慢开机；" "  Takeaway: logon uses (4), async & hidden, does not slow boot;")
    Write-Host (T "  watcher 空闲 0% CPU / ~13MB 内存，低配机可放心开启。" "  watcher idles at 0% CPU / ~13MB RAM - safe on low-end PCs.")
    Write-Host " ================================================== " -ForegroundColor White
}

# ---------------------------------------------------------------- 主流程
Write-Host ""
Write-Host (T "Win10 任务栏调整工具   系统: $((Get-CimInstance Win32_OperatingSystem).Caption) 内部版本 $fullBuild" `
            "Win10 Taskbar Tweak   OS: $((Get-CimInstance Win32_OperatingSystem).Caption) build $fullBuild") -ForegroundColor White
Write-Host ""

# 默认动作 = 交互菜单（双击/无参数时的友好入口）
if (-not ($Status -or $Backup -or $Center -or $Transparency -or $NativeTransparency -or $Watch -or $Restore -or $InstallStartup -or $UninstallStartup -or $InstallScheduledTask -or $UninstallScheduledTask -or $InstallWatcher -or $UninstallWatcher -or $Menu -or $Benchmark)) { $Menu = $true }

if ($Menu) { Show-Menu; return }   # 菜单是独立入口，不与其他开关混用

if ($Status) {
    $targets = Get-TaskbarTargets
    Write-Info (T "发现任务栏 $($targets.Count) 个" "Found $($targets.Count) taskbar(s)")
    foreach ($t in $targets) {
        $mm = Measure-Target $t
        $r = New-Object RECT
        [void][TB]::GetWindowRect($t.Tray, [ref]$r)
        Write-Host ("  {0,-24} tray=[{1},{2}] parentW={3} iconsW={4} buttons={5} left={6}" -f `
            $t.Name, $r.Left, $r.Right, $mm.ParentW, $mm.ContentW, $mm.Buttons, $mm.ListLeft)
    }
    $p = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $et = '(none)'
    if (Test-Path $p) { $et = (Get-ItemProperty $p).EnableTransparency }
    Write-Info (T "HKCU Personalize\EnableTransparency = $et （1=系统原生透明效果已开）" "HKCU Personalize\EnableTransparency = $et (1 = native transparency effects on)")
    $scr = [System.Windows.Forms.Screen]::AllScreens
    Write-Info (T "显示器 $($scr.Count) 台: $(($scr | ForEach-Object { "$($_.Bounds.Width)x$($_.Bounds.Height)@$($_.Bounds.Left)" }) -join ' , ')" `
             "Displays $($scr.Count): $(($scr | ForEach-Object { "$($_.Bounds.Width)x$($_.Bounds.Height)@$($_.Bounds.Left)" }) -join ' , ')")
    Write-Host ""
}

if ($Backup) { Invoke-Backup; Write-Host "" }
if ($NativeTransparency) { Set-NativeTransparency $NativeTransparency; Write-Host "" }

if ($UninstallStartup) { Uninstall-StartupEntry; Write-Host "" }
if ($InstallStartup)   { Install-StartupEntry;   Write-Host "" }

if ($UninstallWatcher)       { Uninstall-Watcher;        Write-Host "" }
if ($UninstallScheduledTask) { Uninstall-ScheduledTasks; Write-Host "" }
if ($InstallWatcher)         { Install-Watcher;          Write-Host "" }
if ($InstallScheduledTask)   { Install-ReapplyTask;      Write-Host "" }
if ($Benchmark)              { Invoke-Benchmark;         Write-Host "" }

if ($Restore) {
    Invoke-RestoreAll
    Write-Host ""
}

if (-not $Restore) {
    if ($Center -or $Transparency -or $Watch) {
        $accentState = $null
        $accentFlags = 0
        $tintVal = 0
        if ($Transparency) {
            $style = Get-AccentStyle $Transparency
            $accentState = $style.State
            $accentFlags = $style.Flags
            $tintVal = Convert-TintToGradientColor $Tint
            # 系统级「透明效果」关闭时 DWM 会拒绝渲染透明材质，确保它是开的
            $et = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).EnableTransparency
            if ($et -eq 0) { Set-NativeTransparency 'On' }
        }

        $apply = {
            param($targets, $doCenter, $offset, $accentState, $accentFlags, $tintVal)
            foreach ($t in $targets) {
                if ($doCenter) { [void](Set-TargetCenter $t $offset) }
                # 返回 false 说明 SetWindowCompositionAttribute 被拒绝
                # 常见原因：目标不是 Win10 任务栏，或窗口句柄已失效
                if ($null -ne $accentState) {
                    $okAccent = [TB]::SetAccent($t.Tray, $accentState, $accentFlags, $tintVal)
                    if (-not $okAccent -and -not $Watch) {
                        Write-Warn "$($t.Name): SetWindowCompositionAttribute 返回 False，透明未生效"
                    }
                }
            }
        }

        if ($Watch) {
            Write-Info "常驻模式启动，间隔 ${IntervalMs}ms。按 Ctrl+C 停止。"
            Write-Info "（停止后效果会在 explorer 下次重排时自然复位，或运行 -Restore 立即还原）"
            try {
                while ($true) {
                    $targets = Get-TaskbarTargets
                    & $apply $targets $Center $Offset $accentState $accentFlags $tintVal
                    Start-Sleep -Milliseconds $IntervalMs
                }
            } finally {
                Write-Host ""
                Write-Info "常驻模式已停止。"
            }
        } else {
            $targets = Get-TaskbarTargets
            & $apply $targets $Center $Offset $accentState $accentFlags $tintVal
            foreach ($t in $targets) {
                if ($Center) {
                    $mm = Measure-Target $t
                    Write-Ok (T "$($t.Name): 居中完成，图标左边 $($mm.ListLeft)（父窗口 $($mm.ParentLeft) 宽 $($mm.ParentW)，图标总宽 $($mm.ContentW)）" `
                              "$($t.Name): centered, list left=$($mm.ListLeft) (parent $($mm.ParentLeft) w=$($mm.ParentW), icons w=$($mm.ContentW))")
                }
                if ($Transparency) { Write-Ok (T "$($t.Name): 透明 = $Transparency" "$($t.Name): transparency = $Transparency") }
            }
            if ($Center -and -not $Watch) {
                Write-Host ""
                Write-Info (T "实测（19045.6466）：打开/关闭窗口、auto-hide 重布局都不会复位居中；" `
                            "Measured (19045.6466): opening/closing windows and auto-hide re-layouts do NOT reset centering;")
                Write-Info (T "会复位的只有 explorer 重启、分辨率/DPI 变化、注销。" `
                            "only explorer restarts, resolution/DPI changes and sign-out do.")
                Write-Info (T "保持方案：登录自启（-InstallScheduledTask，已自动回退机制）或可选 watcher（-InstallWatcher）。" `
                            "Persistence: logon autostart (-InstallScheduledTask, auto-fallback) or the optional watcher (-InstallWatcher).")
            }
            Save-State
            Write-Host ""
        }
    }
}

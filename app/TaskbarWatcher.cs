// ============================================================================
//  TaskbarWatcher.exe — Win10 任务栏轻量驻留组件（可选，默认不安装）
//
//  作用：explorer 重启、分辨率/DPI 变化、系统设置变动后，即时恢复
//        ① 任务栏图标居中  ② accent 透明效果。
//        这是"不常驻"方案（启动项/计划任务一次性应用）无法覆盖的场景的补位选项。
//
//  资源占用：WinEvent 事件驱动，只订阅 explorer 进程的任务栏相关窗口事件，
//            空闲 CPU ≈ 0%；.NET Framework 4 winexe，内存约 5~10MB。
//
//  用法：TaskbarWatcher.exe [--style=clear|blur|acrylic|normal] [--tint=AARRGGBB]
//                           [--offset=N] [--anchor=screen|usable]
//                           [--no-center] [--primary-only]
//  编译：build.cmd（用系统自带的 csc.exe，无需安装任何东西）
//
//  退出：结束进程即可（Uninstall.cmd / -UninstallWatcher 会自动结束）。
// ============================================================================

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Accessibility;

static class TaskbarWatcher
{
    // ---------------------------------------------------------------- Win32
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct MSG
    {
        public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam;
        public uint time; public int ptX; public int ptY;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string win);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr lp);
    delegate bool EnumProc(IntPtr h, IntPtr lp);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr SetProcessDpiAwarenessContext(IntPtr v);

    [DllImport("user32.dll")] static extern bool SetWindowCompositionAttribute(IntPtr h, ref WCAData d);
    [StructLayout(LayoutKind.Sequential)] struct WCAData { public int Attribute; public IntPtr Data; public int Size; }
    [StructLayout(LayoutKind.Sequential)] struct AccentPolicy { public int State; public int Flags; public int Color; public int Anim; }

    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint thread, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
    delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);

    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr w, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr SetTimer(IntPtr hwnd, UIntPtr id, uint ms, IntPtr proc);
    [DllImport("user32.dll")] static extern bool KillTimer(IntPtr hwnd, UIntPtr id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClass(ref WNDCLASS wc);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProc(IntPtr h, uint msg, IntPtr w, IntPtr l);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WNDCLASS
    {
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra, cbWndExtra;
        public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
    }
    delegate IntPtr WndProcDelegate(IntPtr h, uint msg, IntPtr w, IntPtr l);
    static WndProcDelegate g_wndProcKeepAlive;           // 防止委托被 GC 回收（原生代码持有指针）
    static IntPtr g_msgWnd = IntPtr.Zero;
    static readonly IntPtr HWND_MESSAGE = new IntPtr(-3);

    [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr hwnd, int objid, ref Guid riid, out IntPtr ppv);
    [DllImport("oleacc.dll")] static extern int AccessibleChildren(IAccessible container, int start, int count, [In, Out] object[] vars, out int obtained);
    static readonly Guid IID_IAccessible = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");

    // ---------------------------------------------------------------- 常量
    const uint WM_TIMER = 0x0113;
    const int OBJID_CLIENT = -4;
    const uint EVENT_OBJECT_CREATE = 0x8000, EVENT_OBJECT_DESTROY = 0x8001, EVENT_OBJECT_LOCATIONCHANGE = 0x800B;
    const uint WINEVENT_OUTOFCONTEXT = 0, WINEVENT_SKIPOWNPROCESS = 2;
    const uint SWP_NOSIZE = 0x0001, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010, SWP_NOSENDCHANGING = 0x0400;

    const int ACCENT_DISABLED = 0, ACCENT_TRANSPARENT = 2, ACCENT_BLUR = 3, ACCENT_ACRYLIC = 4;
    // 实测 19045：state=2(Clear) 必须带 ACCENT_FLAG_GRADIENT_COLOR(0x2)，否则 DWM 忽略
    // GradientColor，把任务栏画成不透明的系统强调色。
    const int FLAG_GRADIENT_COLOR = 0x2;

    // ---------------------------------------------------------------- 状态
    static int g_state = ACCENT_TRANSPARENT, g_flags = FLAG_GRADIENT_COLOR, g_color = 0;
    static bool g_center = true, g_primaryOnly = false, g_anchorScreen = true;
    static int g_offset = 0;
    static bool g_applyOnce = false;
    static bool g_dirty = false, g_fastTimerActive = false;
    static long g_guardCount = 0;
    static uint g_explorerPid = 0;
    static IntPtr g_hookLoc = IntPtr.Zero, g_hookCrt = IntPtr.Zero;
    static readonly IntPtr TimerFast = new IntPtr(1), TimerGuard = new IntPtr(2);

    // NULL 句柄的线程定时器在 WinEvent 钩子场景下不投递 WM_TIMER（实测 19045），
    // 所以挂在一个 message-only 窗口上——这也是最稳妥的做法。
    static IntPtr CreateMsgWindow()
    {
        g_wndProcKeepAlive = WndProcThunk;
        var wc = new WNDCLASS();
        wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(g_wndProcKeepAlive);
        wc.hInstance = Marshal.GetHINSTANCE(typeof(TaskbarWatcher).Module);
        wc.lpszClassName = "Win10TaskbarTweakWatcher";
        RegisterClass(ref wc);
        return CreateWindowEx(0, wc.lpszClassName, "", 0, 0, 0, 0, 0, HWND_MESSAGE, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
    }

    static IntPtr WndProcThunk(IntPtr h, uint msg, IntPtr w, IntPtr l)
    {
        const uint WM_TIMER = 0x0113;
        if (msg == WM_TIMER) { OnTimer(w); return IntPtr.Zero; }
        return DefWindowProc(h, msg, w, l);
    }

    static void OnTimer(IntPtr id)
    {
        if (id == TimerFast)
        {
            KillTimer(g_msgWnd, (UIntPtr)TimerFast.ToInt64());
            g_fastTimerActive = false;
            if (g_dirty)
            {
                g_dirty = false;
                CheckExplorerPid();          // explorer 重启的 CREATE 事件会先到这里，立刻重挂 hook
                ApplyAll();
            }
        }
        else if (id == TimerGuard)
        {
            GuardTick();
        }
    }

    // 检测 explorer pid 变化并重挂 LOCATIONCHANGE 钩子；返回 true 表示发生了重启
    static bool CheckExplorerPid()
    {
        IntPtr tray = FindWindow("Shell_TrayWnd", null);
        if (tray == IntPtr.Zero) return false;
        uint pid = 0;
        GetWindowThreadProcessId(tray, out pid);
        if (pid == 0 || pid == g_explorerPid) return false;
        Log("explorer pid changed " + g_explorerPid + " -> " + pid + ", rehooking");
        HookExplorer();
        return true;
    }

    class Target { public IntPtr Tray, Parent, List; }

    // ---------------------------------------------------------------- 日志（诊断用；正式版可留空）
    static readonly string LogFile = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TaskbarWatcher.log");

    static void Log(string s)
    {
        try { System.IO.File.AppendAllText(LogFile, DateTime.Now.ToString("HH:mm:ss.fff") + " " + s + "\r\n"); } catch { }
    }

    // ---------------------------------------------------------------- Main
    [STAThread]
    static int Main(string[] args)
    {
        Log("=== watcher start, args: " + string.Join(" ", args) + " log=" + LogFile);
        ParseArgs(args);
        if (g_state == ACCENT_DISABLED && !g_center) return 0;   // 没有任何要维护的效果

        try { SetProcessDpiAwarenessContext((IntPtr)(-4)); } catch { }   // 双屏异 DPI 时坐标必须用物理像素

        // --apply-once：应用一次立即退出。开机自启走这里（毫秒级，不依赖 PowerShell）。
        if (g_applyOnce)
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            ApplyAll();
            Log("apply-once done in " + sw.ElapsedMilliseconds + " ms");
            return 0;
        }

        bool created;
        var mutex = new Mutex(true, @"Local\Win10TaskbarTweak-Watcher", out created);
        if (!created) return 0;                                   // 单实例

        g_msgWnd = CreateMsgWindow();                             // 定时器必须挂在真窗口上（见下）
        Log("msg window=0x" + g_msgWnd.ToString("X"));

        ApplyAll();                                               // 启动先应用一次（explorer 可能已就绪）
        Log("initial apply done");

        HookExplorer();
        Log("hooks set, explorerPid=" + g_explorerPid);

        // 只有"兜底校验"是常设定时器；150ms 去抖定时器按需启停（空闲时零唤醒）
        SetTimer(g_msgWnd, (UIntPtr)TimerGuard.ToInt64(), 15000, IntPtr.Zero);
        Log("entering message loop");

        MSG m;
        while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0)
        {
            TranslateMessage(ref m);
            DispatchMessage(ref m);
        }
        Log("message loop exited");
        return 0;
    }

    static void ParseArgs(string[] args)
    {
        foreach (string raw in args)
        {
            string a = raw.TrimStart('-');
            string[] kv = a.Split(new[] { '=' }, 2);
            string k = kv[0].ToLowerInvariant(), v = kv.Length > 1 ? kv[1] : "";
            switch (k)
            {
                case "style":
                    switch (v.ToLowerInvariant())
                    {
                        case "normal":  g_state = ACCENT_DISABLED;   g_flags = 0; break;
                        case "blur":    g_state = ACCENT_BLUR;       g_flags = 0; break;
                        case "acrylic": g_state = ACCENT_ACRYLIC;    g_flags = FLAG_GRADIENT_COLOR; break;
                        default:        g_state = ACCENT_TRANSPARENT; g_flags = FLAG_GRADIENT_COLOR; break;
                    }
                    break;
                case "tint":
                    try
                    {
                        uint argb = Convert.ToUInt32(v, 16);          // 输入按 AARRGGBB
                        uint abgr = ((argb >> 24) & 0xFF) << 24      // GradientColor 实际是 0xAABBGGRR
                                  | ((argb >> 16) & 0xFF) << 0
                                  | ((argb >> 8) & 0xFF) << 8
                                  | (argb & 0xFF) << 16;
                        g_color = unchecked((int)abgr);
                    }
                    catch { }
                    break;
                case "offset": int.TryParse(v, out g_offset); break;
                case "anchor": g_anchorScreen = !v.Equals("usable", StringComparison.OrdinalIgnoreCase); break;
                case "no-center": g_center = false; break;
                case "primary-only": g_primaryOnly = true; break;
                case "apply-once": g_applyOnce = true; break;
            }
        }
    }

    // ---------------------------------------------------------------- WinEvent
    static void HookExplorer()
    {
        if (g_hookLoc != IntPtr.Zero) { UnhookWinEvent(g_hookLoc); g_hookLoc = IntPtr.Zero; }
        if (g_hookCrt != IntPtr.Zero) { UnhookWinEvent(g_hookCrt); g_hookCrt = IntPtr.Zero; }
        IntPtr tray = FindWindow("Shell_TrayWnd", null);
        uint pid = 0;
        if (tray != IntPtr.Zero) GetWindowThreadProcessId(tray, out pid);
        g_explorerPid = pid;
        // LOCATIONCHANGE 高频事件 → 只订阅 explorer 进程；CREATE/DESTROY 低频 → 全局订阅，
        // 这样 explorer 重启后新任务栏一创建就能被立即发现（不用等兜底定时器）
        g_hookLoc = SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE,
                                    IntPtr.Zero, OnWinEvent, pid, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
        g_hookCrt = SetWinEventHook(EVENT_OBJECT_CREATE, EVENT_OBJECT_DESTROY,
                                    IntPtr.Zero, OnWinEvent, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }

    static void OnWinEvent(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (idObject != 0 || idChild != 0 || hwnd == IntPtr.Zero) return;   // 只关心窗口本体
        switch (ClassName(hwnd))
        {
            case "Shell_TrayWnd":
            case "Shell_SecondaryTrayWnd":
            case "ReBarWindow32":
            case "MSTaskSwWClass":
            case "MSTaskListWClass":
            case "WorkerW":
                g_dirty = true;
                EnsureFastTimer();                               // 按需起表：空闲时零唤醒
                break;
        }
    }

    static void EnsureFastTimer()
    {
        if (!g_fastTimerActive && g_msgWnd != IntPtr.Zero)
        {
            SetTimer(g_msgWnd, (UIntPtr)TimerFast.ToInt64(), 150, IntPtr.Zero);
            g_fastTimerActive = true;
        }
    }

    static void GuardTick()
    {
        try
        {
            bool full = CheckExplorerPid();          // explorer 重启 → 重挂 hook + 全量重应用
            // 低配机降载：普通兜底只补 accent（无 MSAA 测量）；
            // 全量（含居中）仅在 pid 变化时，外加每 4 次兜底（约 1 分钟）做一次保险自愈
            g_guardCount++;
            if (full || (g_guardCount % 4 == 0)) ApplyAll();
            else ReapplyAccentOnly();
        }
        catch (Exception ex) { Log("GuardTick ERROR: " + ex); }
    }

    // 只重铺 accent（幂等，防被系统设置静默重置），不做 MSAA/居中
    static void ReapplyAccentOnly()
    {
        try
        {
            if (g_state == ACCENT_DISABLED) return;
            foreach (Target t in RefreshTargets()) SetAccent(t.Tray);
        }
        catch (Exception ex) { Log("ReapplyAccentOnly ERROR: " + ex); }
    }

    // ---------------------------------------------------------------- 应用
    static void ApplyAll()
    {
        try
        {
            List<Target> targets = RefreshTargets();
            foreach (Target t in targets)
            {
                if (g_state != ACCENT_DISABLED) SetAccent(t.Tray);
                if (g_center) Center(t);
            }
        }
        catch (Exception ex) { Log("ApplyAll ERROR: " + ex); }
    }

    static List<Target> RefreshTargets()
    {
        var targets = new List<Target>();
        AddTarget(targets, FindWindow("Shell_TrayWnd", null));
        if (!g_primaryOnly)
        {
            EnumWindows(delegate(IntPtr h, IntPtr lp)
            {
                if (ClassName(h) == "Shell_SecondaryTrayWnd") AddTarget(targets, h);
                return true;
            }, IntPtr.Zero);
        }
        return targets;
    }

    static void AddTarget(List<Target> list, IntPtr tray)
    {
        if (tray == IntPtr.Zero) return;
        IntPtr listHwnd = FindDescendant(tray, "MSTaskListWClass");
        if (listHwnd == IntPtr.Zero) return;
        list.Add(new Target { Tray = tray, Parent = GetParent(listHwnd), List = listHwnd });
    }

    static IntPtr FindDescendant(IntPtr root, string cls)
    {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(root, delegate(IntPtr h, IntPtr lp)
        {
            if (found != IntPtr.Zero) return true;
            if (ClassName(h) == cls) found = h;
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static void SetAccent(IntPtr hwnd)
    {
        AccentPolicy ap = new AccentPolicy();
        ap.State = g_state; ap.Flags = g_flags; ap.Color = g_color; ap.Anim = 0;
        WCAData d = new WCAData();
        d.Attribute = 19;                                   // WCA_ACCENT_POLICY
        d.Size = Marshal.SizeOf(typeof(AccentPolicy));
        d.Data = Marshal.AllocHGlobal(d.Size);
        try
        {
            Marshal.StructureToPtr(ap, d.Data, false);
            SetWindowCompositionAttribute(hwnd, ref d);
        }
        finally { Marshal.FreeHGlobal(d.Data); }
    }

    // ---------------------------------------------------------------- 居中
    static string ClassName(IntPtr h)
    {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, 256);
        return sb.ToString();
    }

    // 图标可用的横向区间右界：父窗口右侧最靠左的"非任务列表"兄弟窗口
    // （主屏 = 资讯/天气组件 + TrayNotifyWnd；副屏 = ClockButton）
    static int UsableRight(IntPtr tray, IntPtr parent)
    {
        int right = -1;
        RECT pr; GetWindowRect(parent, out pr);
        EnumChildWindows(tray, delegate(IntPtr h, IntPtr lp)
        {
            if (GetParent(h) != tray) return true;
            string c = ClassName(h);
            if (c == "ReBarWindow32" || c == "MSTaskSwWClass" || c == "WorkerW" || c == "MSTaskListWClass") return true;
            RECT r; GetWindowRect(h, out r);
            if (r.R - r.L <= 0) return true;
            if (r.L < pr.L + 200) return true;               // 左侧簇（Start、搜索占位等）
            if (right < 0 || r.L < right) right = r.L;
            return true;
        }, IntPtr.Zero);
        if (right < 0) { RECT tr; GetWindowRect(tray, out tr); right = tr.R; }
        return right;
    }

    static void Center(Target t)
    {
        int contentW = MeasureContentWidth(t.List);
        if (contentW <= 0) { Log("center: measure failed hwnd=0x" + t.List.ToString("X")); return; }        RECT tr; GetWindowRect(t.Tray, out tr);
        RECT pr; GetWindowRect(t.Parent, out pr);
        int left = pr.L;
        int right = UsableRight(t.Tray, t.Parent);

        long target = g_anchorScreen
            ? (long)tr.L + ((long)(tr.R - tr.L) - contentW) / 2          // 相对整块屏幕居中（Win11 观感）
            : (long)left + ((long)(right - left) - contentW) / 2;        // 在开始按钮与托盘之间居中
        target += g_offset;

        long maxLeft = right - contentW;
        if (target < left) target = left;
        if (maxLeft > left && target > maxLeft) target = maxLeft;

        POINT org = new POINT();
        ClientToScreen(t.Parent, ref org);
        RECT lr; GetWindowRect(t.List, out lr);
        bool ok = SetWindowPos(t.List, IntPtr.Zero, (int)(target - org.X), lr.T - org.Y, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOSENDCHANGING);
        // 稳态下静默；只在目标变化（explorer 重启/改分辨率/按钮数变化）或失败时记日志，防止日志无限增长
        long key = t.List.ToInt64() * 1000000 + target;
        if (!ok || key != g_lastCenterKey)
        {
            Log(string.Format("center: contentW={0} target={1} xParam={2} ok={3}", contentW, target, (int)(target - org.X), ok));
            g_lastCenterKey = key;
        }
    }
    static long g_lastCenterKey = long.MinValue;

    // MSAA 测量图标总宽（相对列表窗口自身左缘），失败返回 -1
    static int MeasureContentWidth(IntPtr listHwnd)
    {
        IAccessible acc = Acc(listHwnd);
        if (acc == null) return -1;
        try
        {
            int l, t, w, h;
            acc.accLocation(out l, out t, out w, out h, 0);
            int selfLeft = l;

            var ids = new List<int>();
            var objs = new List<IAccessible>();
            int childCount = 0;
            try { childCount = acc.accChildCount; } catch { return -1; }
            if (childCount > 0)
            {
                var vars = new object[childCount]; int got;
                if (AccessibleChildren(acc, 0, childCount, vars, out got) == 0)
                {
                    for (int i = 0; i < got; i++)
                    {
                        if (vars[i] is int) ids.Add((int)vars[i]);
                        else { var ia = vars[i] as IAccessible; if (ia != null) objs.Add(ia); }
                    }
                }
            }

            int maxRight = -1, n = 0;
            if (ids.Count > 0)
            {
                foreach (int id in ids)
                {
                    int[] b = Loc(acc, id);
                    if (b == null) continue;
                    n++;
                    if (b[0] + b[2] > maxRight) maxRight = b[0] + b[2];
                }
            }
            else
            {
                foreach (IAccessible o in objs)
                {
                    int role = -1;
                    try { role = Convert.ToInt32(o.get_accRole(0)); } catch { }
                    if (role != 22) continue;                    // 22 = push button 分组
                    int gc = 0;
                    try { gc = o.accChildCount; } catch { continue; }
                    if (gc > 0)
                    {
                        var gvars = new object[gc]; int ggot;
                        if (AccessibleChildren(o, 0, gc, gvars, out ggot) == 0)
                        {
                            foreach (object gv in gvars)
                            {
                                int[] b = (gv is int) ? Loc(o, gv) : Loc(gv as IAccessible, 0);
                                if (b == null) continue;
                                n++;
                                if (b[0] + b[2] > maxRight) maxRight = b[0] + b[2];
                            }
                        }
                    }
                    break;
                }
            }
            if (maxRight < 0 || n == 0) return -1;
            return maxRight - selfLeft;
        }
        finally
        {
            Marshal.FinalReleaseComObject(acc);
        }
    }

    static int[] Loc(IAccessible a, object childId)
    {
        if (a == null) return null;
        try
        {
            int l, t, w, h;
            a.accLocation(out l, out t, out w, out h, childId);
            return new[] { l, t, w, h };
        }
        catch { return null; }
    }

    static IAccessible Acc(IntPtr hwnd)
    {
        Guid g = IID_IAccessible;
        IntPtr p;
        if (AccessibleObjectFromWindow(hwnd, OBJID_CLIENT, ref g, out p) != 0 || p == IntPtr.Zero) return null;
        try { return (IAccessible)Marshal.GetTypedObjectForIUnknown(p, typeof(IAccessible)); }
        catch { return null; }
    }
}

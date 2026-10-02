<#
.SYNOPSIS
    Windows 10 开始菜单美化：统一磁贴底色 / 规范化磁贴图标 / 一键还原。
.DESCRIPTION
    原理：桌面应用的磁贴外观由 exe 旁的 <应用名>.VisualElementsManifest.xml 决定。
    本工具为开始菜单里固定的桌面应用批量生成该清单：
      - BackgroundColor 统一（transparent=跟随系统强调色/主题，或指定 hex）
      - ForegroundText 文字颜色
      - 可选 NormalizeIcons：提取应用图标 → 统一留白居中 → 作为磁贴 Logo，
        解决"有的图标撑满、有的图标很小"的观感问题。
    所有改动均备份可逆；UWP/商店应用的磁贴不受支持（系统限制）。
    布局位置说明：此版本 Windows 的开始菜单布局存储于 CloudStore（不透明二进制），
    无法安全地自动重排磁贴位置；位置调整仍需手动拖动，本工具解决"观感统一"。
.PARAMETER Status
    显示当前固定应用、磁贴尺寸统计、已应用的清单与备份。
.PARAMETER Beautify
    应用美化（需要一次 UAC 提权：部分应用装在 Program Files）。
.PARAMETER Color
    磁贴底色：transparent（默认，跟随主题/强调色）或 6 位 hex（如 17171A）。
.PARAMETER NormalizeIcons
    规范化磁贴图标（提取原图标、统一留白居中）。
.PARAMETER HideLabels
    隐藏磁贴名称（更极简；默认显示）。
.PARAMETER Restore
    还原全部开始菜单改动。
.EXAMPLE
    .\Start-Menu-Tweak.ps1 -Status
    .\Start-Menu-Tweak.ps1 -Beautify                                  # 透明 + 规范图标
    .\Start-Menu-Tweak.ps1 -Beautify -Color 17171A -HideLabels
    .\Start-Menu-Tweak.ps1 -Restore
#>
[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$Beautify,
    [ValidateSet('transparent', 'hex')]
    [string]$ColorMode = 'transparent',
    [AllowEmptyString()]
    [string]$Color = '',
    [switch]$NormalizeIcons,
    [switch]$HideLabels,
    [switch]$Restore,
    [ValidateSet('auto', 'zh', 'en')]
    [string]$Lang = 'auto'
)

$ErrorActionPreference = 'Stop'
$uiLang = if ($Lang -eq 'auto') { [System.Globalization.CultureInfo]::CurrentUICulture.Name } else { $Lang }
$script:IsZh = ($uiLang -match '^zh')
function T([string]$zh, [string]$en) { if ($script:IsZh) { $zh } else { $en } }
$root = Split-Path $PSScriptRoot -Parent          # 项目 app\ 的上级 = 项目根
$smDir     = Join-Path $PSScriptRoot 'StartMenu'
$workDir   = Join-Path $smDir 'work'
$backupDir = Join-Path $smDir 'backup'
$stateFile = Join-Path $smDir 'state.json'
$helperPs1 = Join-Path $PSScriptRoot 'StartMenu-Elevated.ps1'
foreach ($d in $smDir, $workDir, $backupDir) { New-Item -ItemType Directory -Path $d -Force | Out-Null }

$PkgLocal = "$env:LOCALAPPDATA\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy"

function Write-Info($m) { Write-Host "[=] $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "[-] $m" -ForegroundColor Red }

function Get-StartHost {
    Get-Process StartMenuExperienceHost -ErrorAction SilentlyContinue
}
function Restart-StartHost {
    Get-StartHost | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Process "shell:AppsFolder\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy!App"
    Write-Ok (T "开始菜单已重新加载" "Start menu reloaded")
}

# ---------------------------------------------------------------- 导出并解析当前固定布局
function Get-PinnedDesktopApps {
    $exportXml = Join-Path $workDir 'layout-export.xml'
    Export-StartLayout -Path $exportXml -ErrorAction Stop
    [xml]$x = Get-Content $exportXml -Raw -Encoding UTF8
    $ns = New-Object System.Xml.XmlNamespaceManager($x.NameTable)
    $ns.AddNamespace('start', 'http://schemas.microsoft.com/Start/2014/StartLayout')

    $sh = New-Object -ComObject WScript.Shell
    $result = @()
    $groups = $x.SelectNodes('//start:Group', $ns)
    foreach ($g in $groups) {
        foreach ($t in $g.ChildNodes) {
            if ($t.LocalName -ne 'DesktopApplicationTile') { continue }
            $link = [string]$t.DesktopApplicationLinkPath
            if (-not $link) { continue }
            $resolved = $link -replace '^%APPDATA%', $env:APPDATA -replace '^%PROGRAMDATA%', $env:ProgramData `
                              -replace '^%PROGRAMFILES(X86)%', ${env:ProgramFiles(x86)} -replace '^%PROGRAMFILES%', $env:ProgramFiles
            if (-not (Test-Path $resolved)) { continue }
            if ($resolved -notlike '*.lnk') { continue }        # .url 网络磁贴跳过
            try { $lnkObj = $sh.CreateShortcut($resolved) } catch { continue }
            $exe = $lnkObj.TargetPath
            if (-not $exe -or -not (Test-Path $exe) -or $exe -notlike '*.exe') { continue }
            $result += [pscustomobject]@{
                Group   = [string]$g.GetAttribute('Name')
                Link    = $resolved
                Exe     = $exe
                Size    = [string]$t.Size
            }
        }
    }
    # 按目标 exe 去重（多个快捷方式指向同一 exe 只处理一次）
    $result | Sort-Object Exe -Unique
}

function Read-State {
    if (Test-Path $stateFile) { try { Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } } else { $null }
}
function Save-State($st) {
    $st | ConvertTo-Json -Depth 6 | Set-Content $stateFile -Encoding UTF8
}

# ---------------------------------------------------------------- Status
if ($Status -or (-not ($Status -or $Beautify -or $Restore))) {
    Write-Host ""
    Write-Host ("============ " + (T '开始菜单状态' 'Start Menu Status') + " ============") -ForegroundColor White
    try {
        $apps = Get-PinnedDesktopApps
        Write-Info (T ("固定的桌面应用磁贴: {0} 个（另有 UWP/网络磁贴，系统限制无法美化）" -f @($apps).Count) `
                    ("Pinned desktop-app tiles: {0} (UWP/.url tiles cannot be beautified)" -f @($apps).Count))
        $i = 0
        foreach ($a in ($apps | Select-Object -First 100)) {
            $i++
            Write-Host ("  {0,2}. {1}" -f $i, $a.Exe)
        }
    } catch { Write-Err ((T '读取布局失败: ' 'Failed to read layout: ') + $_) }
    $st = Read-State
    if ($st) {
        Write-Info (T ("已应用美化: {0}（{1}，颜色 {2}，图标规范化 {3}，隐藏名称 {4}）" -f @($st.Patched).Count, $st.UpdatedAt, $st.Color, $st.NormalizeIcons, $st.HideLabels) `
                    ("Applied: {0} ({1}, color {2}, icon-normalized {3}, hide-labels {4})" -f @($st.Patched).Count, $st.UpdatedAt, $st.Color, $st.NormalizeIcons, $st.HideLabels))
        if ($st.Patched) { foreach ($p in $st.Patched) { Write-Host ("    " + (T '已改: ' 'patched: ') + $p.Exe) } }
    } else {
        Write-Info (T "尚未应用美化（state.json 不存在）" "Beautify not applied yet (no state.json)")
    }
    Write-Info ((T '备份目录: ' 'Backup dir: ') + $backupDir)
    $datPath = "$PkgLocal\TempState\StartUnifiedTileModelCache.dat"
    Write-Info (T ("布局存储: 此版本为 CloudStore(unifiedtile)；磁贴模型缓存 " + (Test-Path $datPath)) `
              ("Layout store: CloudStore (unifiedtile) on this build; tile model cache: " + (Test-Path $datPath)))
    Write-Host ""
}

# ---------------------------------------------------------------- Beautify
if ($Beautify) {
    if (-not $Color) { $Color = if ($ColorMode -eq 'transparent') { 'transparent' } else { throw (T "-ColorMode hex 时必须给 -Color，如 17171A" "-ColorMode hex requires -Color, e.g. 17171A") } }
    Write-Info (T "解析当前固定的桌面应用..." "Resolving pinned desktop apps...")
    $apps = Get-PinnedDesktopApps
    Write-Info (T ("待处理 {0} 个应用" -f @($apps).Count) ("{0} apps to process" -f @($apps).Count))

    $config = [ordered]@{
        Color         = $Color
        HideLabels    = [bool]$HideLabels
        NormalizeIcons = [bool]$NormalizeIcons
        BackupDir     = $backupDir
        WorkDir       = $workDir
        Apps          = @($apps | ForEach-Object { [ordered]@{ Link = $_.Link; Exe = $_.Exe } })
    }
    $cfgFile = Join-Path $workDir 'beautify-config.json'
    $config | ConvertTo-Json -Depth 5 | Set-Content $cfgFile -Encoding UTF8

    Write-Info (T "提权执行（UAC 弹窗请点『是』；部分应用位于 Program Files / ProgramData）..." `
              "Elevating (click Yes on the UAC prompt; some apps live under Program Files / ProgramData)...")
    $logFile = Join-Path $workDir 'elevated-log.txt'
    Remove-Item $logFile -Force -ErrorAction SilentlyContinue
    try {
        $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$helperPs1`"", '-Config', "`"$cfgFile`"", '-Log', "`"$logFile`""
        )
        if ($p.ExitCode -ne 0) { Write-Warn (T "提权进程退出码 $($p.ExitCode)" "Elevated process exit code $($p.ExitCode)") }
    } catch {
        Write-Err (T "提权被取消或失败: $($_.Exception.Message)" "Elevation cancelled or failed: $($_.Exception.Message)")
        return
    }
    if (Test-Path $logFile) { Get-Content $logFile -Encoding UTF8 | ForEach-Object { Write-Host ("    " + $_) } }
    else { Write-Warn (T "未收到提权进程日志（可能 UAC 被取消）" "No elevated log received (UAC may have been cancelled)") }

    Restart-StartHost
    Save-State ([ordered]@{
        UpdatedAt      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Color          = $Color
        HideLabels     = [bool]$HideLabels
        NormalizeIcons = [bool]$NormalizeIcons
        Patched        = @($apps | ForEach-Object { [ordered]@{ Exe = $_.Exe; Link = $_.Link } })
    })
    Write-Ok (T ("已写入 {0} 个应用的统一外观清单。" -f @($apps).Count) ("Manifests written for {0} apps." -f @($apps).Count))
    Write-Warn (T "重要：磁贴外观在『固定那一刻』被系统快照，已固定的磁贴不会自动换新装。生效方式：" `
                 "Important: tile appearance is snapshotted at pin time; already-pinned tiles need a re-pin to pick it up:")
    Write-Info (T "  · 对想立即换装的磁贴：右键磁贴 → 从“开始”屏幕取消固定 → 在所有应用列表右键该应用 → 固定到“开始”屏幕（会排到分组末尾）" `
              "  · Per tile: right-click tile > Unpin from Start > right-click the app in All-apps > Pin to Start (lands at group end)")
    Write-Info (T "  · 以后新固定的应用会自动使用统一外观" "  · Newly pinned apps get the unified look automatically")
    Write-Info (T "还原：菜单 [7] → [2]，或 Start-Menu-Tweak.ps1 -Restore" "Restore: menu [7] > [2], or Start-Menu-Tweak.ps1 -Restore")
}

# ---------------------------------------------------------------- Restore
if ($Restore) {
    $st = Read-State
    if (-not $st) { Write-Warn (T "没有已应用的美化记录（state.json 不存在），无需还原。" "No beautify record found (no state.json); nothing to restore."); return }
    $config = [ordered]@{
        Restore   = $true
        BackupDir = $backupDir
        WorkDir   = $workDir
        Apps      = @($st.Patched | ForEach-Object { [ordered]@{ Exe = $_.Exe; Link = $_.Link } })
    }
    $cfgFile = Join-Path $workDir 'restore-config.json'
    $config | ConvertTo-Json -Depth 5 | Set-Content $cfgFile -Encoding UTF8

    Write-Info (T "提权还原（UAC 请点『是』）..." "Restoring (click Yes on the UAC prompt)...")
    $logFile = Join-Path $workDir 'elevated-log.txt'
    Remove-Item $logFile -Force -ErrorAction SilentlyContinue
    try {
        Start-Process powershell -Verb RunAs -Wait -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$helperPs1`"", '-Config', "`"$cfgFile`"", '-Log', "`"$logFile`""
        ) | Out-Null
    } catch { Write-Err (T "提权被取消或失败: $($_.Exception.Message)" "Elevation cancelled or failed: $($_.Exception.Message)"); return }
    if (Test-Path $logFile) { Get-Content $logFile -Encoding UTF8 | ForEach-Object { Write-Host ("    " + $_) } }

    Restart-StartHost
    Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    Write-Ok (T "开始菜单已还原为系统默认外观。" "Start menu restored to the system default look.")
}

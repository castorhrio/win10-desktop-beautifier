# 开始菜单美化 - 提权辅助脚本（由 Start-Menu-Tweak.ps1 通过 UAC 调用，勿直接运行）
param(
    [Parameter(Mandatory = $true)][string]$Config,
    [Parameter(Mandatory = $true)][string]$Log
)
$ErrorActionPreference = 'Continue'

function L($m) { Add-Content -Path $Log -Value $m -Encoding UTF8 }
L ("=== StartMenu elevated helper " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " ===")

try {
    $cfg = Get-Content $Config -Raw -Encoding UTF8 | ConvertFrom-Json
} catch { L ("config read failed: " + $_); exit 1 }

$backupDir = $cfg.BackupDir
$mfBackup  = Join-Path $backupDir 'manifests'
New-Item -ItemType Directory -Path $mfBackup -Force | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class IconX {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int PrivateExtractIcons(string lpszFile, int nIconIndex, int cxIcon, int cyIcon, IntPtr[] phicon, int[] piconid, int nIcons, int flags);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@

function Get-PathHash([string]$s) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s.ToLower())) | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Save-NormalizedLogos([string]$exe, [string]$logoDir) {
    # 提取 exe 图标 → 统一留白居中 → PNG（150/70 两档）
    New-Item -ItemType Directory -Path $logoDir -Force | Out-Null
    $hicons = New-Object 'IntPtr[]' 1
    $ids    = New-Object 'int[]' 1
    $n = [IconX]::PrivateExtractIcons($exe, 0, 256, 256, $hicons, $ids, 1, 0)
    if ($n -lt 1 -or $hicons[0] -eq [IntPtr]::Zero) {
        $n = [IconX]::PrivateExtractIcons($exe, 0, 48, 48, $hicons, $ids, 1, 0)
    }
    if ($n -lt 1 -or $hicons[0] -eq [IntPtr]::Zero) { L ("    icon extract failed: " + $exe); return $false }
    try {
        $icon = [System.Drawing.Icon]::FromHandle($hicons[0])
        foreach ($spec in @(@{ canvas = 150; inner = 100; file = 'logo150.png' }, @{ canvas = 70; inner = 46; file = 'logo70.png' })) {
            $bmp = New-Object System.Drawing.Bitmap($spec.canvas, $spec.canvas)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = 'AntiAlias'
            $g.Clear([System.Drawing.Color]::Transparent)
            $side = [int]($spec.canvas * ($spec.inner / 100.0))
            $off = [int](($spec.canvas - $side) / 2)
            $g.DrawIcon($icon, (New-Object System.Drawing.Rectangle($off, $off, $side, $side)))
            $g.Dispose()
            $bmp.Save((Join-Path $logoDir $spec.file), [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
        }
        return $true
    } catch { L ("    logo render failed: " + $_.Exception.Message); return $false }
    finally {
        [void][IconX]::DestroyIcon($hicons[0])
        $icon.Dispose()
    }
}

$createdLog = Join-Path $backupDir 'created-files.txt'

if ($cfg.Restore) {
    L "--- RESTORE ---"
    foreach ($app in $cfg.Apps) {
        $exe = $app.Exe
        $dir = Split-Path $exe
        $name = Split-Path $exe -Leaf
        $mf = Join-Path $dir ($name + '.VisualElementsManifest.xml')
        $bak = Join-Path $mfBackup ((Get-PathHash $exe) + '.xml')
        if (Test-Path $bak) {
            Copy-Item $bak $mf -Force
            L ("    restored original manifest: " + $mf)
        } elseif (Test-Path $mf) {
            Remove-Item $mf -Force
            L ("    removed generated manifest: " + $mf)
        }
        $logoDir = Join-Path $dir 'StartMenuBeautify'
        if (Test-Path $logoDir) { Remove-Item $logoDir -Recurse -Force; L ("    removed logos: " + $logoDir) }
        # 触碰 lnk 触发刷新
        if ($app.Link -and (Test-Path $app.Link)) { (Get-Item $app.Link).LastWriteTime = Get-Date }
    }
    L "--- RESTORE DONE ---"
    exit 0
}

# ---------------- 应用美化 ----------------
L ("--- APPLY: color=" + $cfg.Color + " hideLabels=" + $cfg.HideLabels + " normalizeIcons=" + $cfg.NormalizeIcons + " ---")
$fgText = 'light'
foreach ($app in $cfg.Apps) {
    $exe = $app.Exe
    if (-not (Test-Path $exe)) { L ("    skip (exe missing): " + $exe); continue }
    $dir = Split-Path $exe
    $name = Split-Path $exe -Leaf
    $mf = Join-Path $dir ($name + '.VisualElementsManifest.xml')

    # 备份已存在的清单（罕见）
    if ((Test-Path $mf) -and -not (Test-Path (Join-Path $mfBackup ((Get-PathHash $exe) + '.xml')))) {
        Copy-Item $mf (Join-Path $mfBackup ((Get-PathHash $exe) + '.xml')) -Force
        L ("    backed up pre-existing manifest: " + $mf)
    }

    $extra = ''
    if ($cfg.NormalizeIcons) {
        $logoDir = Join-Path $dir 'StartMenuBeautify'
        if (Save-NormalizedLogos $exe $logoDir) {
            $extra = ' Square150x150Logo="StartMenuBeautify\logo150.png" Square70x70Logo="StartMenuBeautify\logo70.png"'
            Add-Content -Path $createdLog -Value $logoDir -Encoding UTF8
        }
    }
    $showName = if ($cfg.HideLabels) { 'off' } else { 'on' }
    $xml = ('<?xml version="1.0" encoding="utf-8"?><Application xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><VisualElements BackgroundColor="{0}" ForegroundText="{1}" ShowNameOnSquare150x150Logo="{2}"{3}/></Application>' -f $cfg.Color, $fgText, $showName, $extra)
    [System.IO.File]::WriteAllText($mf, $xml, (New-Object System.Text.UTF8Encoding $false))
    Add-Content -Path $createdLog -Value $mf -Encoding UTF8
    L ("    manifest written: " + $mf)

    if ($app.Link -and (Test-Path $app.Link)) {
        try { (Get-Item $app.Link).LastWriteTime = Get-Date; L ("    touched lnk: " + $app.Link) }
        catch { L ("    touch lnk FAILED: " + $app.Link + " -> " + $_.Exception.Message) }
    }
}
L "--- APPLY DONE ---"
exit 0

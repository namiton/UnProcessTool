#Requires -Version 5.1
<#
.SYNOPSIS
    ファイル/フォルダをロックしているプロセスを特定し、選択して終了する
.DESCRIPTION
    Windows 標準の Restart Manager API (rstrtmgr.dll) を使用してロック元プロセスを検出する。
    フォルダ指定時は、フォルダをカレントディレクトリとして掴んでいるプロセス
    (cmd / PowerShell で cd しているだけのケース) も PEB 読み取りで検出する。
    終了時はまず通常終了 (RmShutdown による graceful shutdown) を試み、
    残ったプロセスのみ強制終了する。外部ツール (handle.exe 等) は不要。
    -Gui 指定で File Locksmith 風の GUI (WPF) で表示する。
.EXAMPLE
    .\UnProcessTool.ps1 -Path "D:\MyProject\Binaries\Win64" -Gui
.EXAMPLE
    .\UnProcessTool.ps1 -Path "D:\locked.dll" -ListOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    # GUI (WPF) で表示する。コンテキストメニューからは LaunchGui.vbs 経由でこのモードで起動される
    [switch]$Gui,

    # 確認なしで検出した全プロセスを即強制終了する (コンソールモード用。graceful 終了はスキップ)
    [switch]$Force,

    # 一覧表示のみ（終了しない。コンソールモード用）
    [switch]$ListOnly,

    # 終了前にキー入力を待つ（コンソールモード用）
    [switch]$Pause,

    # 指定秒後にウィンドウを自動で閉じる (GUI の自動テスト用)
    [int]$AutoCloseSec = 0
)

$ErrorActionPreference = 'Stop'

$rmSource = @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace UnProcessTool
{
    public class LockerInfo
    {
        public int Pid;
        public string AppName;
        public string AppType;
    }

    public static class RestartManager
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct RM_UNIQUE_PROCESS
        {
            public int dwProcessId;
            public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct RM_PROCESS_INFO
        {
            public RM_UNIQUE_PROCESS Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            public string strAppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
            public string strServiceShortName;
            public int ApplicationType;
            public uint AppStatus;
            public uint TSSessionId;
            [MarshalAs(UnmanagedType.Bool)]
            public bool bRestartable;
        }

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmEndSession(uint pSessionHandle);

        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
            uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
            [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

        [DllImport("rstrtmgr.dll")]
        private static extern int RmShutdown(uint pSessionHandle, uint lActionFlags, IntPtr fnStatus);

        private const int ERROR_MORE_DATA = 234;

        private static string AppTypeName(int t)
        {
            switch (t)
            {
                case 1: return "MainWindow";
                case 2: return "OtherWindow";
                case 3: return "Service";
                case 4: return "Explorer";
                case 5: return "Console";
                case 1000: return "Critical";
                default: return "Unknown";
            }
        }

        public static List<LockerInfo> FindLockers(string[] paths)
        {
            var result = new List<LockerInfo>();
            uint handle;
            string key = Guid.NewGuid().ToString();
            int res = RmStartSession(out handle, 0, key);
            if (res != 0) throw new Exception("RmStartSession failed: " + res);
            try
            {
                const int BATCH = 256;
                for (int i = 0; i < paths.Length; i += BATCH)
                {
                    int len = Math.Min(BATCH, paths.Length - i);
                    var batch = new string[len];
                    Array.Copy(paths, i, batch, 0, len);
                    res = RmRegisterResources(handle, (uint)len, batch, 0, null, 0, null);
                    if (res != 0) throw new Exception("RmRegisterResources failed: " + res);
                }

                uint needed = 0, count = 0, reasons = 0;
                res = RmGetList(handle, out needed, ref count, null, ref reasons);
                while (res == ERROR_MORE_DATA)
                {
                    count = needed;
                    var arr = new RM_PROCESS_INFO[count];
                    res = RmGetList(handle, out needed, ref count, arr, ref reasons);
                    if (res == 0)
                    {
                        for (int i = 0; i < count; i++)
                        {
                            var info = new LockerInfo();
                            info.Pid = arr[i].Process.dwProcessId;
                            info.AppName = arr[i].strAppName;
                            info.AppType = AppTypeName(arr[i].ApplicationType);
                            result.Add(info);
                        }
                    }
                }
                if (res != 0) throw new Exception("RmGetList failed: " + res);
                return result;
            }
            finally
            {
                RmEndSession(handle);
            }
        }

        // 指定したプロセスのみを Restart Manager に登録し、通常終了 (graceful shutdown) を試みる。
        // 保存確認ダイアログを出せるアプリはユーザーの応答を待つ。戻り値は RmShutdown のエラーコード。
        public static int GracefulShutdown(int[] pids)
        {
            var apps = new List<RM_UNIQUE_PROCESS>();
            foreach (int pid in pids)
            {
                try
                {
                    var p = Process.GetProcessById(pid);
                    long ft = p.StartTime.ToFileTime();
                    var u = new RM_UNIQUE_PROCESS();
                    u.dwProcessId = pid;
                    u.ProcessStartTime.dwLowDateTime = (int)(ft & 0xFFFFFFFF);
                    u.ProcessStartTime.dwHighDateTime = (int)(ft >> 32);
                    apps.Add(u);
                }
                catch { } // 開始時刻を取得できないプロセスは graceful 対象外 (呼び出し側で生存確認される)
            }
            if (apps.Count == 0) return -1;

            uint handle;
            string key = Guid.NewGuid().ToString();
            int res = RmStartSession(out handle, 0, key);
            if (res != 0) throw new Exception("RmStartSession failed: " + res);
            try
            {
                res = RmRegisterResources(handle, 0, null, (uint)apps.Count, apps.ToArray(), 0, null);
                if (res != 0) throw new Exception("RmRegisterResources failed: " + res);
                return RmShutdown(handle, 0, IntPtr.Zero); // 0 = 強制終了しない (graceful のみ)
            }
            finally
            {
                RmEndSession(handle);
            }
        }
    }

    // 各プロセスのカレントディレクトリを PEB (RTL_USER_PROCESS_PARAMETERS) から読み取る。
    // Restart Manager では検出できない「フォルダに cd しているだけ」のロックを検出するために使う。
    public static class CwdScanner
    {
        private const uint PROCESS_QUERY_INFORMATION = 0x0400;
        private const uint PROCESS_VM_READ = 0x0010;

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_BASIC_INFORMATION
        {
            public IntPtr Reserved1;
            public IntPtr PebBaseAddress;
            public IntPtr Reserved2_0;
            public IntPtr Reserved2_1;
            public IntPtr UniqueProcessId;
            public IntPtr Reserved3;
        }

        [DllImport("ntdll.dll")]
        private static extern int NtQueryInformationProcess(IntPtr hProcess, int infoClass,
            ref PROCESS_BASIC_INFORMATION pbi, int size, out int retLen);

        [DllImport("ntdll.dll")]
        private static extern int NtQueryInformationProcess(IntPtr hProcess, int infoClass,
            ref IntPtr info, int size, out int retLen);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buffer, IntPtr size, out IntPtr read);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr h);

        [DllImport("kernel32.dll")]
        private static extern bool IsWow64Process(IntPtr h, out bool wow64);

        private static byte[] ReadMem(IntPtr h, IntPtr addr, int len)
        {
            var buf = new byte[len];
            IntPtr read;
            if (!ReadProcessMemory(h, addr, buf, (IntPtr)len, out read) || read.ToInt64() != len) return null;
            return buf;
        }

        // 対象プロセスのカレントディレクトリを返す。取得できない場合 (権限不足等) は null。
        public static string GetProcessCwd(int pid)
        {
            if (!Environment.Is64BitProcess) return null; // 64bit ホスト前提 (オフセットが x64 固定のため)

            IntPtr h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, pid);
            if (h == IntPtr.Zero) return null;
            try
            {
                bool wow64;
                if (!IsWow64Process(h, out wow64)) return null;

                if (wow64)
                {
                    // 32bit プロセス: PEB32 -> ProcessParameters(+0x10) -> CurrentDirectory(+0x24, UNICODE_STRING32)
                    IntPtr peb32 = IntPtr.Zero;
                    int retLen;
                    if (NtQueryInformationProcess(h, 26 /*ProcessWow64Information*/, ref peb32, IntPtr.Size, out retLen) != 0
                        || peb32 == IntPtr.Zero) return null;
                    var buf = ReadMem(h, (IntPtr)(peb32.ToInt64() + 0x10), 4);
                    if (buf == null) return null;
                    uint pp = BitConverter.ToUInt32(buf, 0);
                    if (pp == 0) return null;
                    buf = ReadMem(h, (IntPtr)pp + 0x24, 8);
                    if (buf == null) return null;
                    ushort len = BitConverter.ToUInt16(buf, 0);
                    uint strPtr = BitConverter.ToUInt32(buf, 4);
                    if (len == 0 || strPtr == 0 || len > 65534) return null;
                    buf = ReadMem(h, (IntPtr)strPtr, len);
                    if (buf == null) return null;
                    return System.Text.Encoding.Unicode.GetString(buf);
                }
                else
                {
                    // 64bit プロセス: PEB -> ProcessParameters(+0x20) -> CurrentDirectory(+0x38, UNICODE_STRING)
                    var pbi = new PROCESS_BASIC_INFORMATION();
                    int retLen;
                    if (NtQueryInformationProcess(h, 0 /*ProcessBasicInformation*/, ref pbi,
                        Marshal.SizeOf(typeof(PROCESS_BASIC_INFORMATION)), out retLen) != 0) return null;
                    if (pbi.PebBaseAddress == IntPtr.Zero) return null;
                    var buf = ReadMem(h, (IntPtr)(pbi.PebBaseAddress.ToInt64() + 0x20), 8);
                    if (buf == null) return null;
                    long pp = BitConverter.ToInt64(buf, 0);
                    if (pp == 0) return null;
                    buf = ReadMem(h, (IntPtr)(pp + 0x38), 16);
                    if (buf == null) return null;
                    ushort len = BitConverter.ToUInt16(buf, 0);
                    long strPtr = BitConverter.ToInt64(buf, 8);
                    if (len == 0 || strPtr == 0 || len > 65534) return null;
                    buf = ReadMem(h, (IntPtr)strPtr, len);
                    if (buf == null) return null;
                    return System.Text.Encoding.Unicode.GetString(buf);
                }
            }
            catch { return null; }
            finally { CloseHandle(h); }
        }
    }
}
"@

if (-not ('UnProcessTool.RestartManager' -as [type])) {
    Add-Type -TypeDefinition $rmSource -Language CSharp
}

function Exit-Tool([int]$Code) {
    if ($Pause) { [void](Read-Host "`nEnter キーで閉じます") }
    exit $Code
}

# 共有関数 3 つは GUI のバックグラウンド runspace にも取り込むため、param() を本体側に書く
# ($function:name.ToString() に param ブロックが含まれるようにする)

function Get-TargetFiles {
    param($Item, [int]$MaxFiles = 3000)
    if ($Item.PSIsContainer) {
        return @(Get-ChildItem -LiteralPath $Item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
            Select-Object -First $MaxFiles | ForEach-Object { $_.FullName })
    }
    return @($Item.FullName)
}

function Find-Lockers {
    param([string[]]$TargetFiles)
    if (-not $TargetFiles -or $TargetFiles.Count -eq 0) { return @() }
    $raw = [UnProcessTool.RestartManager]::FindLockers($TargetFiles)
    $seen = @{}
    $list = foreach ($l in $raw) {
        if ($l.Pid -eq $PID) { continue }          # 自分自身は除外
        if ($seen.ContainsKey($l.Pid)) { continue } # PID 重複除去
        $seen[$l.Pid] = $true
        # Restart Manager は既に終了したプロセスを返すことがあるため生存確認
        $proc = Get-Process -Id $l.Pid -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        [pscustomobject]@{
            Pid     = $l.Pid
            Name    = $proc.ProcessName
            AppName = $l.AppName
            Type    = $l.AppType
            ExePath = $(try { $proc.Path } catch { $null })
            Reason  = 'ファイルハンドル'
            CwdPath = $null
        }
    }
    return @($list)
}

# フォルダをカレントディレクトリとして掴んでいるプロセスを検出する
function Find-CwdLockers {
    param([string]$FolderPath)
    $root = $FolderPath.TrimEnd('\') + '\'
    $list = foreach ($proc in Get-Process -ErrorAction SilentlyContinue) {
        if ($proc.Id -eq $PID) { continue }
        $cwd = [UnProcessTool.CwdScanner]::GetProcessCwd($proc.Id)
        if (-not $cwd) { continue }
        $norm = $cwd.TrimEnd('\') + '\'
        if (-not $norm.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { continue }
        [pscustomobject]@{
            Pid     = $proc.Id
            Name    = $proc.ProcessName
            AppName = $proc.ProcessName
            Type    = 'Cwd'
            ExePath = $(try { $proc.Path } catch { $null })
            Reason  = 'カレントディレクトリ'
            CwdPath = $cwd.TrimEnd('\')
        }
    }
    return @($list)
}

function Test-IsAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================================
# GUI モード (File Locksmith 風 / デザインは design-md/microsoft/DESIGN.md 準拠)
# ============================================================================
# ============================================================================
# GUI モード (File Locksmith 風 / デザインは design-md/microsoft/DESIGN.md 準拠)
# Windows 11 スタイル: Mica バックドロップ + カスタムタイトルバー + Fluent アイコン
# ============================================================================
function Show-Gui {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

    if (-not ('UnProcessTool.Dwm' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace UnProcessTool
{
    public static class Dwm
    {
        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    }
}
'@
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        [void][System.Windows.MessageBox]::Show("パスが見つかりません:`n$Path", 'UnProcessTool')
        exit 1
    }
    $item = Get-Item -LiteralPath $Path -Force
    $targetPath = $item.FullName

    # ---- バックグラウンド実行スクリプト (runspace 用) ----
    $scanScript = @'
param($sync, $targetPath)
try {
    $item = Get-Item -LiteralPath $targetPath -Force
    $files = @(Get-TargetFiles -Item $item)
    $lockers = @(Find-Lockers -TargetFiles $files)
    if ($item.PSIsContainer) {
        foreach ($c in @(Find-CwdLockers -FolderPath $item.FullName)) {
            $existing = $lockers | Where-Object { $_.Pid -eq $c.Pid }
            if ($existing) {
                $existing.Reason = "$($existing.Reason) + カレントディレクトリ"
                $existing.CwdPath = $c.CwdPath
            }
            else { $lockers += $c }
        }
    }
    # 所有ユーザー名を付与
    $wmiByPid = @{}
    foreach ($w in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) { $wmiByPid[[int]$w.ProcessId] = $w }
    foreach ($l in $lockers) {
        $user = $null
        $w = $wmiByPid[[int]$l.Pid]
        if ($w) {
            try {
                $o = Invoke-CimMethod -InputObject $w -MethodName GetOwner -ErrorAction Stop
                if ($o.ReturnValue -eq 0) { $user = $o.User }
            } catch { }
        }
        Add-Member -InputObject $l -NotePropertyName User -NotePropertyValue $user
    }
    $sync.Files = $files
    $sync.IsContainer = [bool]$item.PSIsContainer
    $sync.Lockers = $lockers
}
catch { $sync.ScanError = $_.Exception.Message }
$sync.ScanDone = $true
'@

    # どのファイルを掴んでいるかをバイセクト (二分探索) で特定する
    $attribScript = @'
param($sync, $files, $lockerPids)
try {
    $map = @{}
    if ($files.Count -eq 1) {
        foreach ($p in $lockerPids) { $map[[int]$p] = @($files[0]) }
    }
    else {
        $stack = New-Object System.Collections.Stack
        $stack.Push([string[]]$files)
        while ($stack.Count -gt 0) {
            $chunk = [string[]]$stack.Pop()
            $hits = @([UnProcessTool.RestartManager]::FindLockers($chunk) | ForEach-Object { $_.Pid } | Sort-Object -Unique)
            if ($hits.Count -eq 0) { continue }
            if ($chunk.Count -eq 1) {
                foreach ($p in $hits) {
                    if (-not $map.ContainsKey([int]$p)) { $map[[int]$p] = @() }
                    $map[[int]$p] += $chunk[0]
                }
            }
            else {
                $mid = [int][math]::Floor($chunk.Count / 2)
                $stack.Push([string[]]$chunk[0..($mid - 1)])
                $stack.Push([string[]]$chunk[$mid..($chunk.Count - 1)])
            }
        }
    }
    $sync.FileMap = $map
}
catch { $sync.FileMapError = $_.Exception.Message }
$sync.FileMapDone = $true
'@

    # graceful shutdown -> 4 秒待って生きていれば強制終了
    $killScript = @'
param($targetPid)
try { [void][UnProcessTool.RestartManager]::GracefulShutdown([int[]]@([int]$targetPid)) } catch { }
$deadline = (Get-Date).AddSeconds(4)
$alive = $true
while ($alive -and (Get-Date) -lt $deadline) {
    $alive = [bool](Get-Process -Id $targetPid -ErrorAction SilentlyContinue)
    if ($alive) { Start-Sleep -Milliseconds 200 }
}
if ($alive) {
    try { Stop-Process -Id $targetPid -Force -ErrorAction Stop } catch { }
}
'@

    $script:BgTasks = [System.Collections.ArrayList]::new()

    function New-BgTask {
        param([string]$ScriptText, [object[]]$ArgumentList)
        $iss = [initialsessionstate]::CreateDefault()
        foreach ($fn in 'Get-TargetFiles', 'Find-Lockers', 'Find-CwdLockers') {
            $def = (Get-Content "function:$fn").ToString()
            [void]$iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn, $def)))
        }
        $rs = [runspacefactory]::CreateRunspace($iss)
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($ScriptText)
        foreach ($a in $ArgumentList) { [void]$ps.AddArgument($a) }
        $task = @{ PS = $ps; Handle = $ps.BeginInvoke(); RS = $rs }
        [void]$script:BgTasks.Add($task)
        return $task
    }

    # ---- XAML (トークンは DESIGN.md: microsoft のカラーロール/タイポ/スペーシングに準拠) ----
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="UnProcessTool" Width="720" Height="760" MinWidth="560" MinHeight="440"
        Background="#F5F5F5" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI Variable Text, Segoe UI" UseLayoutRounding="True"
        SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="44" ResizeBorderThickness="6" GlassFrameThickness="-1" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <SolidColorBrush x:Key="Ink" Color="#1A1A1A"/>
    <SolidColorBrush x:Key="Muted" Color="#616161"/>
    <SolidColorBrush x:Key="BorderTok" Color="#D1D1D1"/>
    <SolidColorBrush x:Key="Surface" Color="#FAFAFA"/>
    <SolidColorBrush x:Key="Gray050" Color="#F5F5F5"/>
    <SolidColorBrush x:Key="Gray100" Color="#F2F2F2"/>
    <SolidColorBrush x:Key="Blue" Color="#0067B8"/>
    <SolidColorBrush x:Key="BlueBright" Color="#0078D4"/>

    <Style x:Key="CaptionButton" TargetType="Button">
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#14000000"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CaptionCloseButton" TargetType="Button" BasedOn="{StaticResource CaptionButton}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}">
              <ContentPresenter x:Name="cp" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="#C42B1C"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource Blue}"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="40"/>
      <Setter Property="Padding" Value="20,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="20">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource BlueBright}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="SecondaryButton" TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="17"
                    BorderBrush="{StaticResource BorderTok}" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Background" Value="{StaticResource Gray050}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Expander">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style TargetType="{x:Type ScrollBar}">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#C6C6C6" CornerRadius="4" Margin="2,0"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="44"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- カスタムタイトルバー (Mica の上に直接描画) -->
    <Grid Grid.Row="0">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="18,0,0,0">
        <TextBlock Text="&#xE72E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14"
                   Foreground="{StaticResource Blue}" VerticalAlignment="Center"/>
        <TextBlock Text="UnProcessTool" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource Ink}"
                   Margin="10,0,0,0" VerticalAlignment="Center"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top">
        <Button x:Name="BtnMin" Style="{StaticResource CaptionButton}" Content="&#xE921;"/>
        <Button x:Name="BtnClose" Style="{StaticResource CaptionCloseButton}" Content="&#xE8BB;"/>
      </StackPanel>
    </Grid>

    <StackPanel Grid.Row="1" Margin="24,8,24,10">
      <TextBlock x:Name="TitlePath" FontSize="18" FontWeight="SemiBold" Foreground="{StaticResource Ink}"
                 TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="StatusText" FontSize="13" Foreground="{StaticResource Muted}" Margin="0,6,0,0"/>
    </StackPanel>

    <ProgressBar x:Name="ScanProgress" Grid.Row="2" Height="3" Margin="24,0,24,10"
                 IsIndeterminate="True" Foreground="{StaticResource BlueBright}"
                 Background="{StaticResource Gray100}" BorderThickness="0"/>

    <ScrollViewer Grid.Row="3" VerticalScrollBarVisibility="Auto" Padding="24,2,24,0" Background="Transparent">
      <StackPanel x:Name="ProcList" Margin="0,0,0,16"/>
    </ScrollViewer>

    <Border Grid.Row="4" Background="{StaticResource Surface}" BorderBrush="{StaticResource BorderTok}"
            BorderThickness="0,1,0,0" Padding="24,14">
      <Grid>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
          <Button x:Name="BtnRefresh" Style="{StaticResource SecondaryButton}" Height="40">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE72C;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center"/>
              <TextBlock Text="更新" Margin="7,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
          <Button x:Name="BtnAdmin" Style="{StaticResource SecondaryButton}" Height="40" Margin="8,0,0,0" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE7EF;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center"/>
              <TextBlock Text="管理者として再実行" Margin="7,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
        </StackPanel>
        <Button x:Name="BtnKillAll" Style="{StaticResource PrimaryButton}" HorizontalAlignment="Right" IsEnabled="False">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE71A;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13" VerticalAlignment="Center"/>
            <TextBlock Text="すべて終了" Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
        </Button>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

    $window = [Windows.Markup.XamlReader]::Parse($xaml)
    $tbTitle = $window.FindName('TitlePath')
    $tbStatus = $window.FindName('StatusText')
    $procList = $window.FindName('ProcList')
    $scanProgress = $window.FindName('ScanProgress')
    $btnRefresh = $window.FindName('BtnRefresh')
    $btnAdmin = $window.FindName('BtnAdmin')
    $btnKillAll = $window.FindName('BtnKillAll')
    $btnMin = $window.FindName('BtnMin')
    $btnClose = $window.FindName('BtnClose')

    $bc = New-Object System.Windows.Media.BrushConverter
    $brInk = $bc.ConvertFromString('#1A1A1A')
    $brMuted = $bc.ConvertFromString('#616161')
    $brBorder = $bc.ConvertFromString('#D1D1D1')
    $brWhite = $bc.ConvertFromString('#FFFFFF')
    $brGreen = $bc.ConvertFromString('#107C10')
    $brGray050 = $bc.ConvertFromString('#F5F5F5')
    $monoFont = New-Object System.Windows.Media.FontFamily('Cascadia Code, Consolas')
    $iconFont = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')

    $tbTitle.Text = $targetPath
    $tbTitle.ToolTip = $targetPath
    $isAdmin = Test-IsAdmin
    if (-not $isAdmin) { $btnAdmin.Visibility = 'Visible' }

    # Mica バックドロップ (Windows 11 22H2+)。失敗時/ダークテーマ時は Background=#F5F5F5 のまま
    $window.Add_SourceInitialized({
            try {
                $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
                # DWM 既定のタイトルバー塗り (アクセント色) を無効化 (DWMWA_CAPTION_COLOR = COLOR_NONE)
                $none = -2
                [void][UnProcessTool.Dwm]::DwmSetWindowAttribute($helper.Handle, 35, [ref]$none, 4)
                # ライトテーマ (DESIGN.md のトークンが前提) のときのみ Mica を有効化
                $appsLight = 1
                try {
                    $appsLight = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme
                }
                catch { }
                if ($appsLight -eq 1) {
                    $val = 2  # DWMSBT_MAINWINDOW (Mica)
                    $ret = [UnProcessTool.Dwm]::DwmSetWindowAttribute($helper.Handle, 38, [ref]$val, 4)
                    if ($ret -eq 0) {
                        $src = [System.Windows.Interop.HwndSource]::FromHwnd($helper.Handle)
                        $src.CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
                        $window.Background = [System.Windows.Media.Brushes]::Transparent
                    }
                }
            }
            catch { }
        })

    # ---- GUI 状態 ----
    $script:Sync = $null
    $script:Rendered = $false
    $script:FilesRendered = $false
    $script:RowByPid = @{}
    $script:Killing = @{}
    $script:KilledAny = $false
    $script:EmptyShown = $false

    function New-Tb {
        param([string]$Text, [double]$Size, $Brush, [string]$Weight = 'Normal')
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $Text
        $tb.FontSize = $Size
        $tb.Foreground = $Brush
        $tb.FontWeight = $Weight
        $tb.TextTrimming = 'CharacterEllipsis'
        return $tb
    }

    function Add-CardAnimated {
        param($Card, [int]$Index)
        $Card.Opacity = 0
        $tt = New-Object System.Windows.Media.TranslateTransform(0, 10)
        $Card.RenderTransform = $tt
        [void]$procList.Children.Add($Card)

        $ease = New-Object System.Windows.Media.Animation.CubicEase
        $ease.EasingMode = 'EaseOut'
        $delay = [TimeSpan]::FromMilliseconds(50 * $Index)

        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
        $fade.From = 0; $fade.To = 1
        $fade.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(240))
        $fade.EasingFunction = $ease
        $fade.BeginTime = $delay

        $slide = New-Object System.Windows.Media.Animation.DoubleAnimation
        $slide.From = 10; $slide.To = 0
        $slide.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(240))
        $slide.EasingFunction = $ease
        $slide.BeginTime = $delay

        $Card.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
        $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
    }

    function Remove-CardAnimated {
        param($Card)
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
        $fade.To = 0
        $fade.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(160))
        $panel = $procList
        $fade.Add_Completed({ $panel.Children.Remove($Card) }.GetNewClosure())
        $Card.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    }

    function Show-EmptyState {
        if ($script:EmptyShown) { return }
        $script:EmptyShown = $true

        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.HorizontalAlignment = 'Center'
        $panel.Margin = New-Object System.Windows.Thickness(0, 64, 0, 0)

        $circle = New-Object System.Windows.Controls.Border
        $circle.Width = 64; $circle.Height = 64
        $circle.CornerRadius = 32
        $circle.Background = $brWhite
        $circle.BorderBrush = $brBorder
        $circle.BorderThickness = 1
        $circle.HorizontalAlignment = 'Center'
        $glyph = New-Object System.Windows.Controls.TextBlock
        $glyph.FontFamily = $iconFont
        $glyph.FontSize = 26
        $glyph.HorizontalAlignment = 'Center'
        $glyph.VerticalAlignment = 'Center'
        if ($script:KilledAny) {
            $glyph.Text = [char]0xE930   # Completed
            $glyph.Foreground = $brGreen
            $mainText = 'ロックはすべて解除されました'
            $subText = 'このファイル/フォルダは削除・移動できるはずです'
        }
        else {
            $glyph.Text = [char]0xE721   # Search
            $glyph.Foreground = $brMuted
            $mainText = 'ロックしているプロセスは見つかりませんでした'
            $subText = '管理者権限や別ユーザーのプロセスが掴んでいる可能性があります'
        }
        $circle.Child = $glyph
        [void]$panel.Children.Add($circle)

        $main = New-Tb -Text $mainText -Size 15 -Brush $brInk -Weight 'SemiBold'
        $main.HorizontalAlignment = 'Center'
        $main.Margin = New-Object System.Windows.Thickness(0, 16, 0, 0)
        [void]$panel.Children.Add($main)

        $sub = New-Tb -Text $subText -Size 12 -Brush $brMuted
        $sub.HorizontalAlignment = 'Center'
        $sub.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
        [void]$panel.Children.Add($sub)

        Add-CardAnimated -Card $panel -Index 0
    }

    function Update-Status {
        $n = $script:RowByPid.Count
        if ($n -gt 0) {
            $tbStatus.Text = "$n 個のプロセスがこの項目をロックしています"
            $btnKillAll.IsEnabled = $true
        }
        else {
            $btnKillAll.IsEnabled = $false
            $tbStatus.Text = ''
            if ($script:Rendered) { Show-EmptyState }
        }
    }

    function Start-KillFor {
        param([int]$KillPid)
        if ($script:Killing.ContainsKey($KillPid)) { return }
        $row = $script:RowByPid[$KillPid]
        if (-not $row) { return }
        $row.Btn.IsEnabled = $false
        $row.BtnLabel.Text = '終了中…'
        $row.FailText.Visibility = 'Collapsed'
        $task = New-BgTask -ScriptText $killScript -ArgumentList @($KillPid)
        $script:Killing[$KillPid] = @{ Row = $row; Task = $task }
    }

    function Get-ExeIconImage {
        param([string]$ExePath)
        if (-not $ExePath) { return $null }
        try {
            $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
            if (-not $ico) { return $null }
            $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $ico.Handle, [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            $src.Freeze()
            $ico.Dispose()
            $img = New-Object System.Windows.Controls.Image
            $img.Source = $src
            $img.Width = 28; $img.Height = 28
            return $img
        }
        catch { return $null }
    }

    function New-ProcRow {
        param($Info)
        $card = New-Object System.Windows.Controls.Border
        $card.Background = $brWhite
        $card.BorderBrush = $brBorder
        $card.BorderThickness = 1
        $card.CornerRadius = 12
        $card.Padding = New-Object System.Windows.Thickness(16)
        $card.Margin = New-Object System.Windows.Thickness(0, 0, 0, 12)

        # DESIGN.md --shadow-soft 相当。ホバーで浮き上がる
        $shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
        $shadow.BlurRadius = 16
        $shadow.ShadowDepth = 2
        $shadow.Direction = 270
        $shadow.Opacity = 0.06
        $shadow.Color = [System.Windows.Media.Colors]::Black
        $card.Effect = $shadow
        $card.Add_MouseEnter({ param($s, $e) $s.Effect.Opacity = 0.16 })
        $card.Add_MouseLeave({ param($s, $e) $s.Effect.Opacity = 0.06 })

        $grid = New-Object System.Windows.Controls.Grid
        $cIcon = New-Object System.Windows.Controls.ColumnDefinition
        $cIcon.Width = 'Auto'
        $cText = New-Object System.Windows.Controls.ColumnDefinition
        $cBtn = New-Object System.Windows.Controls.ColumnDefinition
        $cBtn.Width = 'Auto'
        [void]$grid.ColumnDefinitions.Add($cIcon)
        [void]$grid.ColumnDefinitions.Add($cText)
        [void]$grid.ColumnDefinitions.Add($cBtn)

        # 実行ファイルの実アイコン (取得できなければ Fluent グリフ)
        $iconHolder = New-Object System.Windows.Controls.Border
        $iconHolder.Width = 36; $iconHolder.Height = 36
        $iconHolder.CornerRadius = 8
        $iconHolder.Background = $brGray050
        $iconHolder.VerticalAlignment = 'Top'
        $iconHolder.Margin = New-Object System.Windows.Thickness(0, 0, 12, 0)
        $img = Get-ExeIconImage -ExePath $Info.ExePath
        if ($img) {
            $iconHolder.Child = $img
        }
        else {
            $fallback = New-Object System.Windows.Controls.TextBlock
            $fallback.Text = [char]0xE756   # CommandPrompt
            $fallback.FontFamily = $iconFont
            $fallback.FontSize = 16
            $fallback.Foreground = $brMuted
            $fallback.HorizontalAlignment = 'Center'
            $fallback.VerticalAlignment = 'Center'
            $iconHolder.Child = $fallback
        }
        [System.Windows.Controls.Grid]::SetColumn($iconHolder, 0)
        [void]$grid.Children.Add($iconHolder)

        $left = New-Object System.Windows.Controls.StackPanel

        $line1 = New-Object System.Windows.Controls.StackPanel
        $line1.Orientation = 'Horizontal'
        [void]$line1.Children.Add((New-Tb -Text $Info.AppName -Size 15 -Brush $brInk -Weight 'SemiBold'))
        $pidTb = New-Tb -Text "PID $($Info.Pid)" -Size 12 -Brush $brMuted
        $pidTb.Margin = New-Object System.Windows.Thickness(8, 3, 0, 0)
        [void]$line1.Children.Add($pidTb)
        [void]$left.Children.Add($line1)

        $metaParts = @()
        if ($Info.User) { $metaParts += "ユーザー: $($Info.User)" }
        $metaParts += "ロック方法: $($Info.Reason)"
        $meta = New-Tb -Text ($metaParts -join '　') -Size 12 -Brush $brMuted
        $meta.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
        [void]$left.Children.Add($meta)

        if ($Info.CwdPath) {
            $cwdTb = New-Tb -Text $Info.CwdPath -Size 12 -Brush $brMuted
            $cwdTb.FontFamily = $monoFont
            $cwdTb.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
            $cwdTb.ToolTip = $Info.CwdPath
            [void]$left.Children.Add($cwdTb)
        }

        if ($Info.ExePath) {
            $exeTb = New-Tb -Text $Info.ExePath -Size 12 -Brush $brMuted
            $exeTb.Opacity = 0.8
            $exeTb.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
            $exeTb.ToolTip = $Info.ExePath
            [void]$left.Children.Add($exeTb)
        }

        $failText = New-Tb -Text '終了できませんでした（管理者権限が必要かもしれません）' -Size 12 -Brush $brMuted
        $failText.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
        $failText.Visibility = 'Collapsed'
        [void]$left.Children.Add($failText)

        $expander = $null
        $filesPanel = $null
        if ($Info.Reason -like '*ファイルハンドル*') {
            $expander = New-Object System.Windows.Controls.Expander
            $expander.Header = 'ロック中のファイル'
            $expander.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
            $filesPanel = New-Object System.Windows.Controls.StackPanel
            $filesPanel.Margin = New-Object System.Windows.Thickness(12, 6, 0, 0)
            $loading = New-Tb -Text '調査中…' -Size 12 -Brush $brMuted
            $loading.FontFamily = $monoFont
            [void]$filesPanel.Children.Add($loading)
            $expander.Content = $filesPanel
            [void]$left.Children.Add($expander)
        }

        [System.Windows.Controls.Grid]::SetColumn($left, 1)
        [void]$grid.Children.Add($left)

        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $window.Resources['SecondaryButton']
        $btnLabel = New-Object System.Windows.Controls.TextBlock
        $btnLabel.Text = 'タスクの終了'
        $btn.Content = $btnLabel
        $btn.VerticalAlignment = 'Top'
        $btn.Margin = New-Object System.Windows.Thickness(12, 0, 0, 0)
        $btn.Tag = [int]$Info.Pid
        $btn.Add_Click({
                param($s, $e)
                Start-KillFor -KillPid ([int]$s.Tag)
            })
        [System.Windows.Controls.Grid]::SetColumn($btn, 2)
        [void]$grid.Children.Add($btn)

        $card.Child = $grid
        return @{ Card = $card; Btn = $btn; BtnLabel = $btnLabel; FilesPanel = $filesPanel; Expander = $expander; FailText = $failText; Info = $Info }
    }

    function Start-Scan {
        $script:Sync = [hashtable]::Synchronized(@{})
        $script:Rendered = $false
        $script:FilesRendered = $false
        $script:RowByPid = @{}
        $script:Killing = @{}
        $script:EmptyShown = $false
        $procList.Children.Clear()
        $btnKillAll.IsEnabled = $false
        $scanProgress.Visibility = 'Visible'
        $tbStatus.Text = 'ロックしているプロセスを検索しています…'
        [void](New-BgTask -ScriptText $scanScript -ArgumentList @($script:Sync, $targetPath))
    }

    function Render-ScanResult {
        $sync = $script:Sync
        $scanProgress.Visibility = 'Collapsed'
        if ($sync.ScanError) {
            $tbStatus.Text = "エラー: $($sync.ScanError)"
            return
        }
        $i = 0
        foreach ($l in @($sync.Lockers)) {
            $row = New-ProcRow -Info $l
            Add-CardAnimated -Card $row.Card -Index $i
            $script:RowByPid[[int]$l.Pid] = $row
            $i++
        }
        Update-Status

        # ファイルハンドル持ちがいればどのファイルを掴んでいるか特定を開始
        $handlePids = @($sync.Lockers | Where-Object { $_.Reason -like '*ファイルハンドル*' } | ForEach-Object { [int]$_.Pid })
        if ($handlePids.Count -gt 0 -and @($sync.Files).Count -gt 0) {
            [void](New-BgTask -ScriptText $attribScript -ArgumentList @($sync, [string[]]@($sync.Files), [int[]]$handlePids))
        }
        else {
            $sync.FileMapDone = $true
            $sync.FileMap = @{}
        }
    }

    function Render-FileMap {
        $sync = $script:Sync
        $map = $sync.FileMap
        $root = $targetPath.TrimEnd('\') + '\'
        foreach ($rowPid in @($script:RowByPid.Keys)) {
            $row = $script:RowByPid[$rowPid]
            if (-not $row.FilesPanel) { continue }
            $row.FilesPanel.Children.Clear()
            $flist = @()
            if ($map -and $map.ContainsKey([int]$rowPid)) { $flist = @($map[[int]$rowPid]) }
            if ($flist.Count -eq 0) {
                $row.Expander.Header = 'ロック中のファイル'
                $tb = New-Tb -Text '特定できませんでした（モジュール/サブプロセス経由の可能性）' -Size 12 -Brush $brMuted
                [void]$row.FilesPanel.Children.Add($tb)
                continue
            }
            $row.Expander.Header = "ロック中のファイル ($($flist.Count))"
            $shown = $flist | Select-Object -First 50
            foreach ($f in $shown) {
                $rel = if ($f.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $f.Substring($root.Length) } else { $f }
                $tb = New-Tb -Text $rel -Size 12 -Brush $brMuted
                $tb.FontFamily = $monoFont
                $tb.ToolTip = $f
                [void]$row.FilesPanel.Children.Add($tb)
            }
            if ($flist.Count -gt 50) {
                $tb = New-Tb -Text "…他 $($flist.Count - 50) 件" -Size 12 -Brush $brMuted
                [void]$row.FilesPanel.Children.Add($tb)
            }
        }
    }

    # ---- イベント ----
    $btnMin.Add_Click({ $window.WindowState = 'Minimized' })
    $btnClose.Add_Click({ $window.Close() })
    $btnRefresh.Add_Click({ Start-Scan })

    $btnAdmin.Add_Click({
            $argList = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Gui -Path "{1}"' -f $PSCommandPath, $targetPath)
            try {
                Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -WindowStyle Hidden
                $window.Close()
            }
            catch { } # UAC キャンセル時は何もしない
        })

    $btnKillAll.Add_Click({
            foreach ($rowPid in @($script:RowByPid.Keys)) { Start-KillFor -KillPid $rowPid }
        })

    # ---- ポーリングタイマー (バックグラウンド結果の反映とプロセス生存監視) ----
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
            $sync = $script:Sync
            if (-not $sync) { return }

            if ($sync.ScanDone -and -not $script:Rendered) {
                $script:Rendered = $true
                Render-ScanResult
            }
            if ($sync.FileMapDone -and -not $script:FilesRendered -and $script:Rendered) {
                $script:FilesRendered = $true
                Render-FileMap
            }

            foreach ($killPid in @($script:Killing.Keys)) {
                $k = $script:Killing[$killPid]
                $alive = Get-Process -Id $killPid -ErrorAction SilentlyContinue
                if (-not $alive) {
                    Remove-CardAnimated -Card $k.Row.Card
                    $script:RowByPid.Remove($killPid)
                    $script:Killing.Remove($killPid)
                    $script:KilledAny = $true
                    if ($k.Row.Info.Name -ieq 'explorer') {
                        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
                            Start-Process explorer.exe
                        }
                    }
                    Update-Status
                }
                elseif ($k.Task.Handle.IsCompleted) {
                    # graceful + 強制の両方が済んでもまだ生きている -> 権限不足など
                    $k.Row.BtnLabel.Text = '再試行'
                    $k.Row.Btn.IsEnabled = $true
                    $k.Row.FailText.Visibility = 'Visible'
                    $script:Killing.Remove($killPid)
                }
            }
        })
    $timer.Start()

    if ($AutoCloseSec -gt 0) {
        $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
        $closeTimer.Interval = [TimeSpan]::FromSeconds($AutoCloseSec)
        $closeTimer.Add_Tick({ $window.Close() })
        $closeTimer.Start()
    }

    $window.Add_Closed({
            $timer.Stop()
            foreach ($t in $script:BgTasks) {
                try { $t.PS.Dispose(); $t.RS.Dispose() } catch { }
            }
        })

    Start-Scan
    [void]$window.ShowDialog()
    exit 0
}

if ($Gui) { Show-Gui }

# ============================================================================
# コンソールモード
# ============================================================================
try {
    # ---- パス解決 ----
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "パスが見つかりません: $Path" -ForegroundColor Red
        Exit-Tool 1
    }
    $item = Get-Item -LiteralPath $Path -Force

    # ---- 対象ファイル列挙 ----
    $MaxFiles = 3000
    if ($item.PSIsContainer) {
        Write-Host "フォルダ内のファイルを列挙中: $($item.FullName)"
    }
    $files = @(Get-TargetFiles -Item $item -MaxFiles $MaxFiles)
    if ($files.Count -eq $MaxFiles) {
        Write-Host "ファイル数が多いため先頭 $MaxFiles 件のみ検査します" -ForegroundColor Yellow
    }

    # ---- ロック元検出 (ファイルハンドル経由) ----
    Write-Host "ロックしているプロセスを検索中... ($($files.Count) ファイル)"
    $lockers = @(Find-Lockers $files)

    # ---- ロック元検出 (カレントディレクトリ経由、フォルダ指定時のみ) ----
    if ($item.PSIsContainer) {
        Write-Host "カレントディレクトリとして掴んでいるプロセスを検索中..."
        foreach ($c in @(Find-CwdLockers $item.FullName)) {
            $existing = $lockers | Where-Object { $_.Pid -eq $c.Pid }
            if ($existing) {
                $existing.Reason = "$($existing.Reason) + カレントディレクトリ"
            }
            else {
                $lockers += $c
            }
        }
    }

    if ($lockers.Count -eq 0) {
        Write-Host "`nロックしているプロセスは見つかりませんでした。" -ForegroundColor Green
        Write-Host "それでも削除できない場合、次の可能性があります:"
        Write-Host "  - 管理者権限のプロセスが掴んでいる（このツールを管理者として再実行すると検出できる場合あり）"
        Write-Host "  - 別ユーザーのプロセスやネットワーク経由 (SMB) のアクセスが掴んでいる"
        Exit-Tool 0
    }

    Write-Host "`nロックしているプロセス ($($lockers.Count) 件):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $lockers.Count; $i++) {
        $l = $lockers[$i]
        Write-Host ("  [{0}] PID {1,-7} {2}  ({3} / {4})" -f ($i + 1), $l.Pid, $l.AppName, $l.Name, $l.Type)
        $reasonText = $l.Reason
        if ($l.CwdPath) { $reasonText += " ($($l.CwdPath))" }
        Write-Host ("        ロック方法: {0}" -f $reasonText) -ForegroundColor DarkYellow
        if ($l.ExePath) { Write-Host ("        {0}" -f $l.ExePath) -ForegroundColor DarkGray }
    }

    if ($ListOnly) { Exit-Tool 0 }

    # ---- 終了対象の選択 ----
    if ($Force) {
        $targets = $lockers
    }
    else {
        $answer = Read-Host "`n終了するプロセスを選択 (a=すべて / 番号をカンマ区切り / Enter=キャンセル)"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            Write-Host "キャンセルしました。"
            Exit-Tool 0
        }
        if ($answer.Trim() -match '^(a|all)$') {
            $targets = $lockers
        }
        else {
            $indexes = @($answer -split '[,、\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
            $targets = @($indexes | Where-Object { $_ -ge 1 -and $_ -le $lockers.Count } | ForEach-Object { $lockers[$_ - 1] })
            if ($targets.Count -eq 0) {
                Write-Host "有効な番号が指定されませんでした。" -ForegroundColor Red
                Exit-Tool 1
            }
        }
    }

    $explorerInTargets = [bool]($targets | Where-Object { $_.Name -ieq 'explorer' })

    # ---- Phase 1: 通常終了 (graceful shutdown)。-Force 時はスキップ ----
    if (-not $Force) {
        Write-Host "`nまず通常終了を試みます。保存確認ダイアログが表示された場合は応答してください..."
        try {
            [void][UnProcessTool.RestartManager]::GracefulShutdown([int[]]@($targets | ForEach-Object { $_.Pid }))
        }
        catch {
            Write-Host "通常終了の呼び出しに失敗しました: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        Start-Sleep -Milliseconds 500

        $survivors = @($targets | Where-Object { Get-Process -Id $_.Pid -ErrorAction SilentlyContinue })
        foreach ($t in @($targets | Where-Object { -not (Get-Process -Id $_.Pid -ErrorAction SilentlyContinue) })) {
            Write-Host "終了しました (通常終了): PID $($t.Pid) $($t.Name)" -ForegroundColor Green
        }

        if ($survivors.Count -gt 0) {
            Write-Host "`n通常終了できなかったプロセス ($($survivors.Count) 件):" -ForegroundColor Yellow
            $survivors | ForEach-Object { Write-Host "  PID $($_.Pid) $($_.Name)" }
            $confirm = Read-Host "これらを強制終了しますか? (y/N)"
            if ($confirm -match '^[yY]') {
                $targets = $survivors
            }
            else {
                Write-Host "強制終了はキャンセルしました。"
                $targets = @()
            }
        }
        else {
            $targets = @()
        }
    }

    # ---- Phase 2: 強制終了 ($Force 時は全件、それ以外は graceful 後の生存プロセスのみ) ----
    $failed = @()
    foreach ($t in $targets) {
        try {
            Stop-Process -Id $t.Pid -Force -ErrorAction Stop
            Write-Host "終了しました (強制): PID $($t.Pid) $($t.Name)" -ForegroundColor Green
        }
        catch {
            Write-Host "終了できませんでした: PID $($t.Pid) $($t.Name) - $($_.Exception.Message)" -ForegroundColor Red
            $failed += $t
        }
    }

    # explorer を終了した場合は自動で再起動する
    if ($explorerInTargets) {
        Start-Sleep -Milliseconds 800
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
            Write-Host "エクスプローラーを再起動しました。"
        }
    }

    # ---- 権限不足時は管理者での再実行を提案 ----
    if ($failed.Count -gt 0) {
        if (-not (Test-IsAdmin)) {
            $retry = Read-Host "終了できなかったプロセスがあります。管理者権限で再実行しますか? (y/N)"
            if ($retry -match '^[yY]') {
                $argList = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Pause -Path "{1}"' -f $PSCommandPath, $item.FullName)
                Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
                Exit-Tool 0
            }
        }
    }

    # ---- 再チェック ----
    Start-Sleep -Milliseconds 800
    $remaining = @(Find-Lockers $files)
    if ($item.PSIsContainer) {
        foreach ($c in @(Find-CwdLockers $item.FullName)) {
            if (-not ($remaining | Where-Object { $_.Pid -eq $c.Pid })) { $remaining += $c }
        }
    }
    if ($remaining.Count -eq 0) {
        Write-Host "`nロックはすべて解除されました。" -ForegroundColor Green
    }
    else {
        Write-Host "`nまだ $($remaining.Count) 件のプロセスがロックしています:" -ForegroundColor Yellow
        $remaining | ForEach-Object { Write-Host "  PID $($_.Pid) $($_.AppName) [$($_.Reason)]" }
    }
    Exit-Tool 0
}
catch {
    Write-Host "`nエラーが発生しました: $($_.Exception.Message)" -ForegroundColor Red
    Exit-Tool 1
}

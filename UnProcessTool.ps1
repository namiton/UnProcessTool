#Requires -Version 5.1
<#
.SYNOPSIS
    ファイル/フォルダをロックしているプロセスを特定し、選択して終了する
.DESCRIPTION
    Windows 標準の Restart Manager API (rstrtmgr.dll) を使用してロック元プロセスを検出する。
    フォルダ指定時は、フォルダをカレントディレクトリとして掴んでいるプロセス
    (cmd / PowerShell で cd しているだけのケース) も PEB 読み取りで検出する。
    終了時はまず通常終了 (RmShutdown による graceful shutdown) を試み、
    残ったプロセスのみ確認のうえ強制終了する。外部ツール (handle.exe 等) は不要。
.EXAMPLE
    .\UnProcessTool.ps1 -Path "D:\MyProject\Binaries\Win64"
.EXAMPLE
    .\UnProcessTool.ps1 -Path "D:\locked.dll" -ListOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    # 確認なしで検出した全プロセスを即強制終了する (graceful 終了はスキップ)
    [switch]$Force,

    # 一覧表示のみ（終了しない）
    [switch]$ListOnly,

    # 終了前にキー入力を待つ（コンテキストメニュー起動用）
    [switch]$Pause
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

function Find-Lockers([string[]]$TargetFiles) {
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
        }
    }
    return @($list)
}

# フォルダをカレントディレクトリとして掴んでいるプロセスを検出する
function Find-CwdLockers([string]$FolderPath) {
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
            Reason  = "カレントディレクトリ ($($cwd.TrimEnd('\')))"
        }
    }
    return @($list)
}

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
        $files = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
            Select-Object -First $MaxFiles | ForEach-Object { $_.FullName })
        if ($files.Count -eq $MaxFiles) {
            Write-Host "ファイル数が多いため先頭 $MaxFiles 件のみ検査します" -ForegroundColor Yellow
        }
    }
    else {
        $files = @($item.FullName)
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
        Write-Host ("        ロック方法: {0}" -f $l.Reason) -ForegroundColor DarkYellow
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
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
            IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
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

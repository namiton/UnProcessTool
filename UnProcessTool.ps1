#Requires -Version 5.1
<#
.SYNOPSIS
    ファイル/フォルダをロックしているプロセスを特定し、選択して終了する
.DESCRIPTION
    Windows 標準の Restart Manager API (rstrtmgr.dll) を使用してロック元プロセスを検出する。
    外部ツール (handle.exe 等) は不要。
.EXAMPLE
    .\UnProcessTool.ps1 -Path "D:\MyProject\Binaries\Win64"
.EXAMPLE
    .\UnProcessTool.ps1 -Path "D:\locked.dll" -ListOnly
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    # 確認なしで検出した全プロセスを終了する
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
            ExePath = try { $proc.Path } catch { $null }
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

    if ($files.Count -eq 0) {
        Write-Host "フォルダ内に検査対象ファイルがありません（空フォルダ）。" -ForegroundColor Yellow
        Write-Host "空フォルダが削除できない場合は、cmd / PowerShell / エクスプローラーがこのフォルダを開いている（カレントディレクトリにしている）可能性があります。"
        Exit-Tool 0
    }

    # ---- ロック元検出 ----
    Write-Host "ロックしているプロセスを検索中... ($($files.Count) ファイル)"
    $lockers = @(Find-Lockers $files)

    if ($lockers.Count -eq 0) {
        Write-Host "`nロックしているプロセスは見つかりませんでした。" -ForegroundColor Green
        Write-Host "それでも削除できない場合、次の可能性があります:"
        Write-Host "  - cmd / PowerShell がこのフォルダをカレントディレクトリにしている"
        Write-Host "  - 管理者権限のプロセスが掴んでいる（このツールを管理者として再実行すると検出できる場合あり）"
        Exit-Tool 0
    }

    Write-Host "`nロックしているプロセス ($($lockers.Count) 件):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $lockers.Count; $i++) {
        $l = $lockers[$i]
        Write-Host ("  [{0}] PID {1,-7} {2}  ({3} / {4})" -f ($i + 1), $l.Pid, $l.AppName, $l.Name, $l.Type)
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

    # ---- プロセス終了 ----
    $failed = @()
    $explorerKilled = $false
    foreach ($t in $targets) {
        try {
            Stop-Process -Id $t.Pid -Force -ErrorAction Stop
            Write-Host "終了しました: PID $($t.Pid) $($t.Name)" -ForegroundColor Green
            if ($t.Name -ieq 'explorer') { $explorerKilled = $true }
        }
        catch {
            Write-Host "終了できませんでした: PID $($t.Pid) $($t.Name) - $($_.Exception.Message)" -ForegroundColor Red
            $failed += $t
        }
    }

    # explorer を終了した場合は自動で再起動する
    if ($explorerKilled) {
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
    if ($remaining.Count -eq 0) {
        Write-Host "`nロックはすべて解除されました。" -ForegroundColor Green
    }
    else {
        Write-Host "`nまだ $($remaining.Count) 件のプロセスがロックしています:" -ForegroundColor Yellow
        $remaining | ForEach-Object { Write-Host "  PID $($_.Pid) $($_.AppName)" }
    }
    Exit-Tool 0
}
catch {
    Write-Host "`nエラーが発生しました: $($_.Exception.Message)" -ForegroundColor Red
    Exit-Tool 1
}

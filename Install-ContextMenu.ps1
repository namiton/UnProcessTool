#Requires -Version 5.1
# 右クリックメニューに「ロックしているプロセスを調査 (UnProcessTool)」を追加する
# HKCU のみ変更するため管理者権限は不要
$ErrorActionPreference = 'Stop'

$launcherPath = Join-Path $PSScriptRoot 'LaunchGui.vbs'
if (-not (Test-Path -LiteralPath $launcherPath)) {
    throw "LaunchGui.vbs が見つかりません: $launcherPath"
}

$menuText = 'ロックしているプロセスを調査 (UnProcessTool)'
# wscript 経由でコンソールウィンドウなしに GUI を起動する
$command  = 'wscript.exe "{0}" "%1"' -f $launcherPath

# '*' = 全ファイル, 'Directory' = フォルダ
foreach ($class in @('*', 'Directory')) {
    $base = "HKCU:\Software\Classes\$class\shell\UnProcessTool"
    New-Item -Path "$base\command" -Force | Out-Null
    Set-ItemProperty -LiteralPath $base -Name '(default)' -Value $menuText
    Set-ItemProperty -LiteralPath $base -Name 'Icon' -Value 'taskmgr.exe'
    Set-ItemProperty -LiteralPath "$base\command" -Name '(default)' -Value $command
}

Write-Host "コンテキストメニューを登録しました。" -ForegroundColor Green
Write-Host "Windows 11 では右クリック →「その他のオプションを確認」(または Shift+F10) の中に表示されます。"

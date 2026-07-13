#Requires -Version 5.1
# 右クリックメニューに「ロックしているプロセスを調査 (UnProcessTool)」を追加する
# HKCU のみ変更するため管理者権限は不要
$ErrorActionPreference = 'Stop'

$toolPath = Join-Path $PSScriptRoot 'UnProcessTool.ps1'
if (-not (Test-Path -LiteralPath $toolPath)) {
    throw "UnProcessTool.ps1 が見つかりません: $toolPath"
}

$menuText = 'ロックしているプロセスを調査 (UnProcessTool)'
$command  = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Pause -Path "%1"' -f $toolPath

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

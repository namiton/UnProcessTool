#Requires -Version 5.1
# Install-ContextMenu.ps1 で登録した右クリックメニューを削除する
$ErrorActionPreference = 'Stop'

foreach ($class in @('*', 'Directory')) {
    $base = "HKCU:\Software\Classes\$class\shell\UnProcessTool"
    if (Test-Path -LiteralPath $base) {
        Remove-Item -LiteralPath $base -Recurse -Force
        Write-Host "削除しました: $base"
    }
}

Write-Host "コンテキストメニューの登録を解除しました。" -ForegroundColor Green

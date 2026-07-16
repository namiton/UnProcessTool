#Requires -Version 5.1
# Enable-ClassicContextMenu.ps1 の変更を元に戻し、Windows 11 標準の右クリックメニューに戻す。
$ErrorActionPreference = 'Stop'

$key = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
if (Test-Path -LiteralPath $key) {
    Remove-Item -LiteralPath $key -Recurse -Force
    Write-Host "Windows 11 標準の右クリックメニューに戻しました。" -ForegroundColor Green
}
else {
    Write-Host "クラシックメニュー設定は登録されていません。変更はありません。"
}

$answer = Read-Host "今すぐエクスプローラーを再起動して反映しますか? (y/N)"
if ($answer -match '^[yY]') {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
    Write-Host "エクスプローラーを再起動しました。" -ForegroundColor Green
}

#Requires -Version 5.1
# Windows 11 の右クリックメニューを従来型 (クラシック) に戻す。
# これにより UnProcessTool を含む従来メニュー項目が「その他のオプションを確認」なしで直接表示される。
# HKCU のみ変更するため管理者権限は不要。元に戻すには Disable-ClassicContextMenu.ps1 を実行。
$ErrorActionPreference = 'Stop'

$key = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
New-Item -Path $key -Force | Out-Null
Set-ItemProperty -LiteralPath $key -Name '(default)' -Value ''

Write-Host "クラシック右クリックメニューを有効化しました。" -ForegroundColor Green
Write-Host "反映にはエクスプローラーの再起動が必要です。"
$answer = Read-Host "今すぐエクスプローラーを再起動しますか? (y/N)"
if ($answer -match '^[yY]') {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
    Write-Host "エクスプローラーを再起動しました。" -ForegroundColor Green
}
else {
    Write-Host "次回サインイン時、またはエクスプローラー再起動後に反映されます。"
}

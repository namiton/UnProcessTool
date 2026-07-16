#Requires -Version 5.1
# 動作チェック用のロック状況を作る。
# %TEMP%\UnProcessTool-Test フォルダを作成し、以下の2プロセスでロックする:
#   1. 隠しコンソール  : ファイルハンドル + カレントディレクトリ (即時強制終了パスの確認用)
#   2. 通常ウィンドウ  : ファイルハンドル (WM_CLOSE による通常終了パスの確認用)
# プロセスは 5 分で自動終了する。フォルダを右クリック → UnProcessTool で検出・終了を確認する。
$ErrorActionPreference = 'Stop'

$testDir = Join-Path $env:TEMP 'UnProcessTool-Test'
New-Item -ItemType Directory -Path $testDir -Force | Out-Null
Set-Content -LiteralPath "$testDir\locked_hidden.txt" -Value 'locked by hidden console'
Set-Content -LiteralPath "$testDir\locked_window.txt" -Value 'locked by visible console'

# 1. 隠しコンソール (ウィンドウなし -> 「タスクの終了」で即時に強制終了されるはず)
$p1 = Start-Process powershell.exe -WindowStyle Hidden -WorkingDirectory $testDir -PassThru -ArgumentList (
    '-NoProfile', '-Command',
    "`$f = [IO.File]::Open('$testDir\locked_hidden.txt', 'Open', 'Read', 'None'); Start-Sleep 300"
)

# 2. 見えるコンソール (ウィンドウあり -> 閉じる要求で 3 秒以内に通常終了するはず)
$p2 = Start-Process powershell.exe -WindowStyle Minimized -PassThru -ArgumentList (
    '-NoProfile', '-Command',
    "`$host.UI.RawUI.WindowTitle = 'UnProcessTool テストロッカー (ウィンドウあり)'; " +
    "`$f = [IO.File]::Open('$testDir\locked_window.txt', 'Open', 'Read', 'None'); Start-Sleep 300"
)

Write-Host "テスト環境を用意しました:" -ForegroundColor Green
Write-Host "  対象フォルダ : $testDir"
Write-Host "  ロッカー1    : PID $($p1.Id) 隠しコンソール (ファイルハンドル + カレントディレクトリ)"
Write-Host "  ロッカー2    : PID $($p2.Id) ウィンドウ付きコンソール (ファイルハンドル)"
Write-Host ""
Write-Host "このフォルダを右クリック → 「ロックしているプロセスを調査 (UnProcessTool)」で確認してください。"
Write-Host "(ロッカーは 5 分で自動終了します)"
Start-Process explorer.exe $env:TEMP

# UnProcessTool

「別のプログラムがこのフォルダーまたはファイルを開いているので、操作を完了できません。」

このエラーの原因プロセスを特定し、選択して終了する PowerShell ツール。
Windows 標準の **Restart Manager API** (`rstrtmgr.dll`) を使うため、handle.exe などの外部ツールのインストールは不要。

## インストール（推奨: MSI）

[Releases](https://github.com/namiton/UnProcessTool/releases) から最新の `UnProcessTool-x.y.z.msi` をダウンロードして実行する。

- per-user インストール（`%LocalAppData%\Programs\UnProcessTool`）のため **管理者権限・UAC 不要**
- 右クリックメニューの登録もインストーラが自動で行う
- アンインストール（設定 → アプリ → UnProcessTool）でメニュー登録ごと削除される

インストール後、ファイル/フォルダを右クリック → **「ロックしているプロセスを調査 (UnProcessTool)」** で起動。

> Windows 11 の新しい右クリックメニューには表示されない（パッケージアプリ限定のため）。
> **「その他のオプションを確認」** をクリックするか、対象を選択して **Shift+F10** で従来メニューを開くと表示される。

## ファイル構成

| ファイル | 役割 |
|---|---|
| `UnProcessTool.ps1` | 本体。ロック元プロセスの検出・一覧表示・終了 |
| `Install-ContextMenu.ps1` | 右クリックメニューに登録（MSI を使わない場合の手動登録用） |
| `Uninstall-ContextMenu.ps1` | 右クリックメニューから削除（手動登録の解除用） |
| `wix/Package.wxs` | MSI 定義（WiX v5） |
| `build-msi.ps1` | ローカルで MSI をビルドするスクリプト |
| `.github/workflows/release.yml` | タグ push で MSI をビルドし Release に添付する CI |

## セットアップ（スクリプトで手動登録する場合）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "d:\OriginalTool\UnProcessTool\Install-ContextMenu.ps1"
```

登録後、ファイル/フォルダを右クリック → **「ロックしているプロセスを調査 (UnProcessTool)」** で起動できる。

> Windows 11 の新しい右クリックメニューには表示されない（パッケージアプリ限定のため）。
> **「その他のオプションを確認」** をクリックするか、対象を選択して **Shift+F10** で従来メニューを開くと表示される。

解除は `Uninstall-ContextMenu.ps1` を実行。

## コマンドラインでの使い方

```powershell
# 対話モード: ロック元を一覧表示し、番号選択で終了
.\UnProcessTool.ps1 -Path "D:\MyProject\Binaries\Win64"

# 一覧表示のみ（終了しない）
.\UnProcessTool.ps1 -Path "D:\locked.dll" -ListOnly

# 確認なしで検出した全プロセスを終了
.\UnProcessTool.ps1 -Path "D:\MyProject\Binaries\Win64" -Force
```

| パラメータ | 説明 |
|---|---|
| `-Path` | 対象のファイルまたはフォルダ。フォルダの場合は配下のファイルを再帰的に検査（上限 3000 件） |
| `-ListOnly` | 検出のみで終了しない |
| `-Force` | 確認プロンプトなしで全プロセスを終了 |
| `-Pause` | 終了前に Enter 待ち（コンテキストメニュー起動用） |

## 動作の特徴

- **2種類のロックを検出**
  - ファイルハンドル / ロード済みモジュール経由のロック（Restart Manager API）
  - **カレントディレクトリとして掴んでいるだけのロック**（cmd / PowerShell でそのフォルダに `cd` しているケース。各プロセスの PEB から作業ディレクトリを読み取って検出。32bit/64bit プロセス両対応）
- **2段階の終了処理**
  1. まず通常終了（`RmShutdown` による graceful shutdown）を試みる。保存確認ダイアログを出せるアプリはユーザーが応答でき、未保存データを失いにくい
  2. 通常終了できなかったプロセスのみ、確認のうえ強制終了（`-Force` 指定時は最初から強制終了）
- 各プロセスの「ロック方法」（ファイルハンドル / カレントディレクトリ / 両方）を表示
- 自分自身（実行中の PowerShell）は検出対象から除外
- explorer.exe を終了した場合は自動で再起動
- アクセス拒否で終了できなかった場合、管理者権限での再実行を提案
- プロセス終了後に再スキャンし、ロックが解除されたか確認

## 制限事項

- 管理者権限プロセスによるロックは、ツール自身を管理者として実行しないと終了・カレントディレクトリ検出ができない（ファイルハンドル経由の検出は可能な場合が多い）。
- カレントディレクトリ検出は 64bit PowerShell での実行が前提（Windows 標準の PowerShell はすべて 64bit）。
- 別ユーザーのプロセスやネットワーク経由 (SMB) のロックは検出できない。
- フォルダ内のファイルが 3000 件を超える場合、先頭 3000 件のみ検査する。

## 開発者向け: MSI のビルド

リリースは GitHub Actions が自動で行う（`v*` タグを push すると MSI がビルドされ Release に添付される）。

ローカルでビルドする場合は [WiX Toolset](https://wixtoolset.org/) の .NET ツールが必要：

```powershell
# v5 系を指定（v6 以降は OSMF EULA 同意が必要）
dotnet tool install --global wix --version 5.0.2
.\build-msi.ps1 -Version 1.0.0
# → dist\UnProcessTool-1.0.0.msi
```

## ライセンス

MIT License

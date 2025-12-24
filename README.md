PaperCut MFサーバーのSSL証明書を自動更新するPowerShellスクリプトです。OpenSSLとJava keytoolを使用して、サーバー証明書と中間証明書からJavaキーストア（JKS形式）を作成し、PaperCut MFに適用します。

## 概要

このスクリプトは以下の処理を自動化します：

1. **証明書の変換とキーストア作成**
    - OpenSSLを使用してサーバー証明書、秘密鍵、中間証明書をPKCS12形式に変換
    - Java keytoolを使用してPKCS12からJKS形式に変換
2. **PaperCut MFサービスの停止**
    - 証明書適用のためにPCAppServerサービスを一時停止
3. **証明書の配置と設定更新**
    - 作成したキーストアを`server/custom`ディレクトリに配置
    - [`server.properties`](http://server.properties)ファイルを更新して新しいキーストアを参照
4. **PaperCut MFサービスの再起動**
    - サービスを起動して証明書を有効化
5. **詳細なログ記録**
    - すべての処理ステップをログファイルに記録
    - ログのローテーション機能（古いログの自動削除）

## 必要な環境

- **OS**: Windows Server（PowerShell 5.1以降）
- **ソフトウェア**:
    - PaperCut MF（インストール済み）
    - OpenSSL（コマンドラインツール）
    - Java keytool（PaperCut MF同梱版または別途インストール）
- **証明書ファイル**:
    - サーバー証明書（.cerまたは.crt）
    - 秘密鍵ファイル（.key）
    - 中間証明書（.cer）
- **権限**: 管理者権限（サービス操作とファイル配置のため）

## セットアップ

### 1. ファイル構成

スクリプトと設定ファイルを同じディレクトリに配置してください：

```
スクリプトディレクトリ/
├── [UpdateCert.ps](http://UpdateCert.ps)1          # メインスクリプト
├── config.json             # 設定ファイル
└── logs/                   # ログ出力先（自動作成）
```

### 2. config.json の設定

`config.json`を環境に合わせて編集してください：

```json
{
  "security": {
    "privateKeyPassword": "your-private-key-password",
    "keystorePassword": "your-keystore-password"
  },
  "paths": {
    "certDir": "C:\\Certs",
    "paperCutPath": "C:\\Program Files\\PaperCut MF",
    "opensslPath": "openssl"
  },
  "files": {
    "privateKeyName": "your-domain.key",
    "serverCertName": "your-domain.cer",
    "chainCertName": "intermediate_certificate.cer",
    "keystoreName": "my-ssl-keystore"
  },
  "logging": {
    "rotateGen": 10,
    "logFileNamePrefix": "UpdateCert_Log"
  }
}
```

### 設定項目の説明

**security**

- `privateKeyPassword`: 秘密鍵のパスワード
- `keystorePassword`: キーストアに設定するパスワード

**paths**

- `certDir`: 証明書ファイルが格納されているディレクトリ
- `paperCutPath`: PaperCut MFのインストールディレクトリ
- `opensslPath`: OpenSSLコマンドのパス（PATHに含まれている場合は`"openssl"`のまま）

**files**

- `privateKeyName`: 秘密鍵ファイル名
- `serverCertName`: サーバー証明書ファイル名
- `chainCertName`: 中間証明書ファイル名
- `keystoreName`: 作成するキーストアのファイル名（拡張子不要）

**logging**

- `rotateGen`: 保持するログファイルの世代数（古いログは自動削除）
- `logFileNamePrefix`: ログファイル名のプレフィックス

## 使用方法

### 実行前の確認

1. 証明書ファイルが`certDir`に配置されていること
2. `config.json`が正しく設定されていること
3. 管理者権限でPowerShellを起動していること

### スクリプトの実行

PowerShellで以下のコマンドを実行します：

```powershell
.\[UpdateCert.ps](http://UpdateCert.ps)1
```

### 実行結果の確認

- コンソールに処理状況がカラー表示されます
- 詳細なログは`logs/`ディレクトリに保存されます
- ログファイル名: `UpdateCert_Log_YYYYMMDD-HHMMSS.log`

### 処理の流れ

実行時には以下の順序で処理が進みます：

```
[処理開始]
  ↓
1. 設定ファイル読み込み
  ↓
2. ログ初期化・ローテーション
  ↓
3. OpenSSLでPKCS12キーストア作成
  ↓
4. KeytoolでJKSキーストアに変換
  ↓
5. PCAppServerサービス停止
  ↓
6. キーストアを配置
  ↓
7. [server.properties](http://server.properties)を更新
  ↓
8. PCAppServerサービス起動
  ↓
[処理完了]
```

## ログについて

### ログファイルの場所

`logs/`ディレクトリ内に日時付きのログファイルが作成されます。

### ログのローテーション

`config.json`の`rotateGen`で指定した世代数を超えると、古いログファイルから自動削除されます。

### ログの内容

ログには以下の情報が記録されます：

- 各処理ステップの開始・完了状況
- OpenSSLとkeytoolの実行結果（標準出力・標準エラー出力）
- エラー発生時の詳細情報
- タイムスタンプとログレベル（INFO/ERROR）

## トラブルシューティング

### スクリプトがエラーで終了する場合

1. **config.jsonが見つからない**
    - スクリプトと同じディレクトリに`config.json`があるか確認
2. **証明書ファイルが見つからない**
    - `certDir`のパスが正しいか確認
    - 証明書ファイル名が`config.json`と一致しているか確認
3. **OpenSSLまたはkeytoolが見つからない**
    - OpenSSLがインストールされているか確認
    - `opensslPath`が正しいか確認（絶対パスまたはPATH環境変数に含まれていること）
4. **サービスの停止・起動に失敗する**
    - 管理者権限で実行しているか確認
    - PCAppServerサービスが存在するか確認
5. **パスワードエラー**
    - `privateKeyPassword`と`keystorePassword`が正しいか確認

### ログの確認方法

エラーが発生した場合は、`logs/`ディレクトリ内の最新ログファイルを確認してください。エラーの詳細情報が記録されています。

## 注意事項

- **管理者権限必須**: このスクリプトはWindowsサービスを操作するため、管理者権限が必要です
- **サービス停止時間**: 証明書適用中はPaperCut MFサービスが一時停止します（通常数秒程度）
- **バックアップ推奨**: 初回実行前に[`server.properties`](http://server.properties)と既存のキーストアをバックアップすることを推奨します
- **パスワード管理**: `config.json`にはパスワードが平文で保存されるため、ファイルのアクセス権限を適切に設定してください
- **証明書の有効期限**: このスクリプトは証明書の更新作業を自動化するものであり、証明書自体の有効期限管理は別途必要です


## サポート

問題が発生した場合は、ログファイルの内容と合わせてお問い合わせください。

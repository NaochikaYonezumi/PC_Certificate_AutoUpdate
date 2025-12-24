# ========================================================
# PaperCut MF SSL証明書更新スクリプト (詳細ログ版)
# ========================================================

$ErrorActionPreference = "Stop"
$scriptPath = $PSScriptRoot
if (-not $scriptPath) { $scriptPath = Get-Location }
$configPath = Join-Path $scriptPath "config.json"
$logDir = Join-Path $scriptPath "logs"

# --- 関数: ログ出力 (基本) ---
function Write-Log {
    param(
        [string]$Message,
        [string]$Color = "White",
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy/MM/dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    
    # コンソール出力 (エラー以外は指定色、エラーは赤)
    $hostColor = if ($Level -eq "ERROR") { "Red" } else { $Color }
    Write-Host $Message -ForegroundColor $hostColor

    # ファイル出力
    if ($global:CurrentLogPath) {
        Add-Content -Path $global:CurrentLogPath -Value $logLine
    }
}

# --- 関数: 外部ツール実行とログ記録 (詳細ログ用) ---
function Invoke-ToolWithLogging {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$ToolName
    )
    
    # 出力をキャプチャするための一時ファイル
    $tempStdOut = [System.IO.Path]::GetTempFileName()
    $tempStdErr = [System.IO.Path]::GetTempFileName()

    try {
        Write-Log "[$ToolName] コマンドを実行しています..." -Color Gray

        $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -NoNewWindow -PassThru `
            -RedirectStandardOutput $tempStdOut `
            -RedirectStandardError $tempStdErr

        # --- 標準出力のログ記録 ---
        if ((Get-Item $tempStdOut).Length -gt 0) {
            Get-Content $tempStdOut | ForEach-Object { 
                Write-Log "[$ToolName Output] $_" -Color Gray 
            }
        }

        # --- 標準エラー出力のログ記録 (OpenSSL/Keytoolは進捗もここに出すことが多い) ---
        if ((Get-Item $tempStdErr).Length -gt 0) {
            Get-Content $tempStdErr | ForEach-Object { 
                # エラー出力でも、終了コードが0ならINFO扱いで記録
                $lvl = if ($p.ExitCode -eq 0) { "INFO" } else { "ERROR" }
                Write-Log "[$ToolName Message] $_" -Level $lvl -Color Gray 
            }
        }

        if ($p.ExitCode -ne 0) {
            throw "$ToolName が異常終了しました (ExitCode: $($p.ExitCode))"
        }
    }
    finally {
        # 一時ファイルの掃除
        if (Test-Path $tempStdOut) { Remove-Item $tempStdOut }
        if (Test-Path $tempStdErr) { Remove-Item $tempStdErr }
    }
}

# ========================================================
# 初期設定・準備
# ========================================================

# 1. 設定読み込み
if (-not (Test-Path $configPath)) {
    Write-Error "エラー: config.json が見つかりません。"
    exit 1
}
try {
    $config = Get-Content $configPath -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Error "エラー: config.json の読み込み失敗"
    exit 1
}

# 2. ログフォルダとローテーション
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory | Out-Null
    Write-Host "ログ用フォルダを作成しました: $logDir" -ForegroundColor Gray
}

$logPrefix = $config.logging.logFileNamePrefix
$rotateGen = $config.logging.rotateGen
$dateStr = Get-Date -Format "yyyyMMdd-HHmmss"
$global:CurrentLogPath = Join-Path $logDir "${logPrefix}_${dateStr}.log"

# ローテーション
$existingLogs = Get-ChildItem -Path $logDir -Filter "${logPrefix}_*.log" | Sort-Object CreationTimeDescending
if ($existingLogs.Count -ge $rotateGen) {
    $logsToDelete = $existingLogs | Select-Object -Skip ($rotateGen - 1)
    foreach ($file in $logsToDelete) { Remove-Item $file.FullName -Force }
    Write-Host "ログローテーション: 古いログを $($logsToDelete.Count) 件削除しました。" -ForegroundColor Gray
}

Write-Log "処理開始: ログファイル -> $global:CurrentLogPath" -Color Cyan

# 3. 変数マッピング
try {
    $privateKeyPassword = $config.security.privateKeyPassword
    $keystorePassword   = $config.security.keystorePassword

    $certDir         = $config.paths.certDir
    $privateKeyPath  = Join-Path $certDir $config.files.privateKeyName
    $serverCertPath  = Join-Path $certDir $config.files.serverCertName
    $chainCertPath   = Join-Path $certDir $config.files.chainCertName

    $tempP12Path     = Join-Path $certDir "temp_keystore.p12"
    $keystoreName    = $config.files.keystoreName
    $outputJksPath   = Join-Path $certDir $keystoreName
    
    $opensslPath     = $config.paths.opensslPath
    $paperCutPath    = $config.paths.paperCutPath
    $destPath        = Join-Path $paperCutPath "server\custom"
    $serverPropPath  = Join-Path $paperCutPath "server\server.properties"
    $keytoolPath     = Join-Path $paperCutPath "runtime\win64\jre\bin\keytool.exe"
}
catch {
    Write-Log "設定値の読み込み中にエラーが発生しました: $_" -Level ERROR
    exit 1
}

# ========================================================
# メイン処理実行
# ========================================================

# 事前チェック
if (-not (Test-Path $chainCertPath)) {
    Write-Log "エラー: 中間証明書が見つかりません: $chainCertPath" -Level ERROR
    exit 1
}

# --------------------------------------------------------
# Step 1: 証明書の作成
# --------------------------------------------------------
Write-Log "1. 新しいキーストアを作成中..."

# 1-A. PKCS12作成 (OpenSSL)
$opensslArgs = @(
    "pkcs12", "-export",
    "-out", $tempP12Path,
    "-inkey", $privateKeyPath,
    "-in", $serverCertPath,
    "-certfile", $chainCertPath,
    "-passin", "pass:$privateKeyPassword",
    "-passout", "pass:$keystorePassword"
)

try {
    Invoke-ToolWithLogging -FilePath $opensslPath -ArgumentList $opensslArgs -ToolName "OpenSSL"
}
catch {
    Write-Log "OpenSSL処理失敗: $_" -Level ERROR
    exit 1
}

# 1-B. JKS変換 (Keytool)
if (Test-Path $outputJksPath) { Remove-Item $outputJksPath -Force }

try {
    if (-not (Test-Path $keytoolPath)) { 
        Write-Log "PaperCut内蔵のkeytoolが見つかりません。PATH上のkeytoolを使用します。" -Color Yellow
        $keytoolPath = "keytool" 
    }
    
    $keytoolArgs = @(
        "-importkeystore",
        "-srckeystore", $tempP12Path,
        "-srcstoretype", "PKCS12",
        "-srcstorepass", $keystorePassword,
        "-destkeystore", $outputJksPath,
        "-deststoretype", "JKS",
        "-deststorepass", $keystorePassword
    )
    
    Invoke-ToolWithLogging -FilePath $keytoolPath -ArgumentList $keytoolArgs -ToolName "Keytool"
    Write-Log "   -> 証明書作成完了" -Color Green
}
catch {
    Write-Log "Keytool処理失敗: $_" -Level ERROR
    exit 1
}

# --------------------------------------------------------
# Step 2: サービスの停止
# --------------------------------------------------------
Write-Log "2. サービスを停止中..."
try {
    Stop-Service -Name "PCAppServer" -Force -ErrorAction Stop
    Start-Sleep -Seconds 5
    Write-Log "   -> 停止完了" -Color Green
}
catch {
    Write-Log "サービスの停止に失敗しました: $_" -Level ERROR
    exit 1
}

# --------------------------------------------------------
# Step 3: 配置と設定変更
# --------------------------------------------------------
Write-Log "3. ファイル配置と設定更新..."

# 3-A. ファイル配置
if (-not (Test-Path $destPath)) { New-Item -ItemType Directory -Path $destPath | Out-Null }
Copy-Item $outputJksPath "$destPath\$keystoreName" -Force
Write-Log "   -> ファイル配置完了 ($destPath\$keystoreName)" -Color Green

# 3-B. server.properties 更新
try {
    $content = Get-Content $serverPropPath -Encoding UTF8
    $newContent = @()
    $updated = @{ Path=$false; Pass=$false; KeyPass=$false }

    foreach ($line in $content) {
        if ($line -match "^\s*#?\s*server\.ssl\.keystore\s*=") {
            $newContent += "server.ssl.keystore=custom/$keystoreName"
            $updated.Path = $true
        }
        elseif ($line -match "^\s*#?\s*server\.ssl\.keystore-password\s*=") {
            $newContent += "server.ssl.keystore-password=$keystorePassword"
            $updated.Pass = $true
        }
        elseif ($line -match "^\s*#?\s*server\.ssl\.key-password\s*=") {
            $newContent += "server.ssl.key-password=$keystorePassword"
            $updated.KeyPass = $true
        }
        else {
            $newContent += $line
        }
    }

    if (-not $updated.Path)    { $newContent += "server.ssl.keystore=custom/$keystoreName" }
    if (-not $updated.Pass)    { $newContent += "server.ssl.keystore-password=$keystorePassword" }
    if (-not $updated.KeyPass) { $newContent += "server.ssl.key-password=$keystorePassword" }

    $newContent | Set-Content $serverPropPath -Encoding UTF8
    Write-Log "   -> server.properties 更新完了" -Color Green
}
catch {
    Write-Log "server.properties の更新失敗: $_" -Level ERROR
}

# --------------------------------------------------------
# Step 4: サービスの開始
# --------------------------------------------------------
Write-Log "4. サービスを開始中..."
try {
    Start-Service -Name "PCAppServer"
    Write-Log "   -> 起動完了" -Color Green
}
catch {
    Write-Log "サービスの起動に失敗しました: $_" -Level ERROR
    exit 1
}

# --------------------------------------------------------
# 終了処理
# --------------------------------------------------------
if (Test-Path $tempP12Path) { Remove-Item $tempP12Path }

Write-Log "--- 全処理完了 ---" -Color Cyan
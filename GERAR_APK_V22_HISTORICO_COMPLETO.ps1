$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step([string]$text) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host $text -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Download-IfMissing([string]$url, [string]$dest) {
    if (-not (Test-Path $dest)) {
        Write-Host "Baixando: $url"
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    }
}


function Expand-ZipRobust([string]$zipPath, [string]$destination) {
    # O Expand-Archive do Windows PowerShell 5.1 pode falhar em alguns ZIPs
    # oficiais do Android. Esta rotina usa a biblioteca .NET diretamente.
    if (Test-Path $destination) {
        Remove-Item $destination -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $destination | Out-Null

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $destination)
    }
    catch {
        # Fallback para tar.exe, presente no Windows 10/11 moderno.
        Write-Host "Extracao .NET falhou; tentando metodo alternativo do Windows..." -ForegroundColor Yellow
        Get-ChildItem -Path $destination -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        & tar.exe -xf $zipPath -C $destination
        if ($LASTEXITCODE -ne 0) {
            throw "Nao foi possivel extrair $zipPath. Erro: $($_.Exception.Message)"
        }
    }
}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Work = Join-Path $Root '.apk-builder'
$Downloads = Join-Path $Work 'downloads'
$Sdk = Join-Path $Work 'android-sdk'
$JavaRoot = Join-Path $Work 'java'
$GradleRoot = Join-Path $Work 'gradle'
New-Item -ItemType Directory -Force -Path $Downloads, $Sdk, $JavaRoot, $GradleRoot | Out-Null

Write-Host "Calculadora por Voz - GERADOR V2.2 HISTORICO COMPLETO - Gradle 9.6.0" -ForegroundColor Green
Write-Host "O primeiro uso baixa ferramentas oficiais e pode demorar mais." -ForegroundColor Yellow

# 1) JDK 17 portatil
Write-Step '1/5 - Preparando Java 17'
$javaExe = Get-ChildItem -Path $JavaRoot -Filter java.exe -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\bin\\java\.exe$' } | Select-Object -First 1
if (-not $javaExe) {
    $jdkZip = Join-Path $Downloads 'microsoft-jdk-17-windows-x64.zip'
    Download-IfMissing 'https://aka.ms/download-jdk/microsoft-jdk-17-windows-x64.zip' $jdkZip
    Write-Host 'Extraindo Java...'
    Expand-ZipRobust $jdkZip $JavaRoot
    $javaExe = Get-ChildItem -Path $JavaRoot -Filter java.exe -Recurse | Where-Object { $_.FullName -match '\\bin\\java\.exe$' } | Select-Object -First 1
}
if (-not $javaExe) { throw 'Nao foi possivel localizar o Java 17.' }
$env:JAVA_HOME = Split-Path -Parent (Split-Path -Parent $javaExe.FullName)
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
& $javaExe.FullName -version

# 2) Android SDK Command Line Tools
Write-Step '2/5 - Preparando Android SDK'
$sdkManager = Join-Path $Sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
if (-not (Test-Path $sdkManager)) {
    $cmdZip = Join-Path $Downloads 'commandlinetools-win-15859902_latest.zip'
    Download-IfMissing 'https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip' $cmdZip

    $expected = '90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a'
    $actual = (Get-FileHash -Algorithm SHA256 $cmdZip).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        Remove-Item $cmdZip -Force -ErrorAction SilentlyContinue
        throw "A verificacao de seguranca das ferramentas Android falhou. Esperado: $expected / obtido: $actual"
    }

    $tmp = Join-Path $Work 'cmdline-temp'
    Expand-ZipRobust $cmdZip $tmp
    $latest = Join-Path $Sdk 'cmdline-tools\latest'
    New-Item -ItemType Directory -Force -Path (Split-Path $latest -Parent) | Out-Null
    Remove-Item $latest -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item (Join-Path $tmp 'cmdline-tools') $latest
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$env:ANDROID_SDK_ROOT = $Sdk
$env:ANDROID_HOME = $Sdk
$env:Path = "$Sdk\platform-tools;$Sdk\cmdline-tools\latest\bin;$env:Path"

Write-Host 'Aceitando licencas do Android SDK...'
1..100 | ForEach-Object { 'y' } | & $sdkManager --sdk_root=$Sdk --licenses | Out-Host

Write-Host 'Instalando Android 16 (API 36) e ferramentas de compilacao...'
& $sdkManager --sdk_root=$Sdk 'platform-tools' 'platforms;android-36' 'build-tools;36.0.0'
if ($LASTEXITCODE -ne 0) { throw "sdkmanager terminou com codigo $LASTEXITCODE" }

# local.properties
$sdkForGradle = $Sdk.Replace('\','/')
Set-Content -Path (Join-Path $Root 'local.properties') -Value "sdk.dir=$sdkForGradle" -Encoding ASCII

# 3) Gradle 9.6.0
Write-Step '3/5 - Preparando Gradle 9.6.0'
$gradleBat = Join-Path $GradleRoot 'gradle-9.6.0\bin\gradle.bat'
if (-not (Test-Path $gradleBat)) {
    # Apaga qualquer arquivo antigo com o nome errado usado nas primeiras versoes.
    Remove-Item (Join-Path $Downloads 'gradle-9.6-bin.zip') -Force -ErrorAction SilentlyContinue

    $gradleZip = Join-Path $Downloads 'gradle-9.6.0-bin.zip'
    $gradleUrl = 'https://services.gradle.org/distributions/gradle-9.6.0-bin.zip'

    # Se houver um ZIP parcial de uma tentativa anterior, baixa novamente.
    if (Test-Path $gradleZip) {
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $testZip = [System.IO.Compression.ZipFile]::OpenRead($gradleZip)
            $hasEntries = $testZip.Entries.Count -gt 0
            $testZip.Dispose()
            if (-not $hasEntries) { throw 'ZIP vazio' }
        }
        catch {
            Remove-Item $gradleZip -Force -ErrorAction SilentlyContinue
        }
    }

    Download-IfMissing $gradleUrl $gradleZip

    Write-Host 'Extraindo Gradle 9.6.0...'
    $gradleExtractTmp = Join-Path $Work 'gradle-temp'
    Expand-ZipRobust $gradleZip $gradleExtractTmp

    Get-ChildItem -Path $GradleRoot -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    $extractedGradle = Join-Path $gradleExtractTmp 'gradle-9.6.0'
    if (-not (Test-Path $extractedGradle)) {
        throw 'O ZIP foi baixado, mas a pasta gradle-9.6.0 nao foi encontrada.'
    }

    Move-Item $extractedGradle (Join-Path $GradleRoot 'gradle-9.6.0')
    Remove-Item $gradleExtractTmp -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path $gradleBat)) {
    throw 'Nao foi possivel preparar o Gradle 9.6.0.'
}

# 4) Build
Write-Step '4/5 - Compilando o aplicativo'
Push-Location $Root
try {
    & $gradleBat --no-daemon --stacktrace clean assembleDebug
    if ($LASTEXITCODE -ne 0) { throw "Gradle terminou com codigo $LASTEXITCODE" }
}
finally {
    Pop-Location
}

# 5) Copy final APK
Write-Step '5/5 - Preparando o APK final'
$sourceApk = Join-Path $Root 'app\build\outputs\apk\debug\app-debug.apk'
$finalApk = Join-Path $Root 'Calculadora_por_Voz_Galaxy_A17_V22_HISTORICO_COMPLETO.apk'
if (-not (Test-Path $sourceApk)) { throw 'A compilacao terminou, mas o APK nao foi encontrado.' }
Copy-Item $sourceApk $finalApk -Force

Write-Host ''
Write-Host 'PRONTO!' -ForegroundColor Green
Write-Host "APK criado em:" -ForegroundColor Green
Write-Host $finalApk -ForegroundColor White
Write-Host ''
Write-Host 'Agora envie esse arquivo .apk para o Galaxy A17 e abra-o no celular para instalar.' -ForegroundColor Yellow

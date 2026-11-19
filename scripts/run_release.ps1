# Build and launch in --release so the app can be opened from the home screen
# without a debugger. Dropbox keys come from a local .env (gitignored).
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

if (-not (Test-Path -LiteralPath '.env')) {
    Write-Error @"
Missing .env — copy .env.example to .env and set DROPBOX_APP_KEY:
  Copy-Item .env.example .env
"@
    exit 1
}

# Gradle 9.3/9.4's embedded Kotlin does not fully support running the daemon on JDK 25.
# Prefer a local JDK 17–21 if JAVA_HOME is 25+.
$jdk21 = 'C:\Program Files\Eclipse Adoptium\jdk-21.0.11.10-hotspot'
if ((Test-Path -LiteralPath $jdk21) -and ($env:JAVA_HOME -match 'jdk-2[5-9]|jdk-[3-9]')) {
    $env:JAVA_HOME = $jdk21
    $env:PATH = "$jdk21\bin;$env:PATH"
    Write-Host "Using JAVA_HOME=$env:JAVA_HOME (Gradle Kotlin DSL)"
}

& fvm flutter run --release --dart-define-from-file=.env @args

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

& fvm flutter run --release --dart-define-from-file=.env @args

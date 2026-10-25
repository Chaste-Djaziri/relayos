param(
    [string]$Python = ".venv\Scripts\python.exe",
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $root
$env:Path = "C:\Program Files\dotnet;" + $env:Path

if (-not (Test-Path $Python)) { throw "Python runtime not found: $Python" }
& $Python -m pip install -e ".[dev]"
dotnet publish Native\RelayOSWindows\RelayOSWindows.csproj -c $Configuration -p:Platform=x64 --no-restore

$output = Join-Path $root "Native\RelayOSWindows\bin\x64\$Configuration\net8.0-windows10.0.19041.0"
$runtime = Join-Path $output "Runtime"
New-Item -ItemType Directory -Force -Path $runtime | Out-Null

# Keep the Python environment beside the native executable. The supervisor
# prefers Runtime\python.exe, while development still falls back to .venv.
$venv = (Resolve-Path (Split-Path -Parent $Python)).Path | Split-Path -Parent
if (Test-Path (Join-Path $runtime "python.exe")) { Remove-Item -LiteralPath $runtime -Recurse -Force }
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
Get-ChildItem -LiteralPath $venv -Force | Copy-Item -Destination $runtime -Recurse -Force

$ngrok = Get-Command ngrok.exe -ErrorAction SilentlyContinue
if ($ngrok) { Copy-Item -LiteralPath $ngrok.Source -Destination (Join-Path $runtime "ngrok.exe") -Force }

Write-Host "Native Windows app published to $output"
Write-Host "Runtime bundled: $(Test-Path (Join-Path $runtime 'python.exe'))"
Write-Host "ngrok bundled: $(Test-Path (Join-Path $runtime 'ngrok.exe'))"

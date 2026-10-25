param(
    [string]$Python = "",
    [string]$Version = "0.1.0"
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $root
$env:Path = "C:\Program Files\dotnet;" + $env:Path

if ([string]::IsNullOrWhiteSpace($Python)) {
    $Python = (Get-Command python.exe -ErrorAction Stop).Source
} elseif (-not (Test-Path -LiteralPath $Python)) {
    # Local developer builds commonly pass the venv path, while CI uses the
    # interpreter installed by actions/setup-python. Fall back to that runner
    # interpreter when the local venv does not exist.
    $runnerPython = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($runnerPython) {
        Write-Host "Python runtime '$Python' was not found; using $($runnerPython.Source)."
        $Python = $runnerPython.Source
    } else {
        throw "Python runtime not found: $Python"
    }
}
Write-Host "Using Python runtime: $Python"
& $Python -m pip install --upgrade pip
& $Python -m pip install -e ".[dev]"

$nativeProject = "Native\RelayOSWindows\RelayOSWindows.csproj"
dotnet restore $nativeProject -p:Platform=x64
dotnet publish $nativeProject -c Release -p:Platform=x64 --no-restore

$publishedExe = Get-ChildItem "Native\RelayOSWindows\bin" -Recurse -Filter "RelayOSWindows.exe" |
    Where-Object { $_.FullName -match "Release" } |
    Select-Object -First 1
if (-not $publishedExe) { throw "Native RelayOSWindows.exe was not produced" }

$stage = Join-Path $root "dist\windows-native\RelayOS"
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Get-ChildItem -LiteralPath $publishedExe.Directory.FullName -Force | Copy-Item -Destination $stage -Recurse -Force

$runtime = Join-Path $stage "Runtime"
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
$build = Join-Path $root "build\windows-native"
if (Test-Path $build) { Remove-Item -LiteralPath $build -Recurse -Force }
New-Item -ItemType Directory -Force -Path $build | Out-Null

# Bundle the Python MCP backend into a standalone executable. End users do not
# need Python installed; the native companion supervises this helper directly.
& $Python -m PyInstaller --noconfirm --clean --onefile --console `
    --name RelayOSServer --distpath $runtime --workpath (Join-Path $build "pyinstaller") `
    --specpath $build --paths src --collect-submodules laptop_bridge `
    --collect-all mcp --collect-all mcp_types `
    packaging\relayos_server_entry.py

$ngrok = Get-Command ngrok.exe -ErrorAction SilentlyContinue
if ($ngrok) { Copy-Item -LiteralPath $ngrok.Source -Destination (Join-Path $runtime "ngrok.exe") -Force }

$iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if (-not $iscc) { throw "Inno Setup 6 (ISCC.exe) is required to create the installer" }
& $iscc.Source "packaging\windows-installer.iss" "/DSourceDir=$stage" "/DAppVersion=$Version"

$zip = Join-Path $root "dist\RelayOS-Windows-$Version.zip"
if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip
Write-Host "Windows installer: dist\installer\RelayOS-Setup-$Version.exe"
Write-Host "Windows portable archive: $zip"

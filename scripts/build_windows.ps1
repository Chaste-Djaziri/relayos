param(
    [string]$Python = "python",
    [string]$Version = "0.1.0"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$Dist = Join-Path $Root "dist\\windows"
$Build = Join-Path $Root "build\\windows"

& $Python -m pip install -e ".[dev]"
& $Python -m PyInstaller --noconfirm --clean --windowed --onedir `
    --name "Laptop Bridge" --distpath $Dist --workpath $Build --specpath $Build `
    --paths src --collect-submodules pynput `
    --hidden-import mcp.server --hidden-import mcp.server.auth --hidden-import mcp.server.transport_security `
    packaging/desktop_entry.py

$Executable = Join-Path $Dist "Laptop Bridge\\Laptop Bridge.exe"
if (-not (Test-Path $Executable)) { throw "PyInstaller did not create $Executable" }

if ($env:LAPTOP_BRIDGE_SIGNING_CERTIFICATE) {
    $SignTool = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if (-not $SignTool) { throw "signtool.exe is required when LAPTOP_BRIDGE_SIGNING_CERTIFICATE is set" }
    $SignArgs = @("sign", "/fd", "SHA256", "/tr", "http://timestamp.digicert.com", "/td", "SHA256", "/f", $env:LAPTOP_BRIDGE_SIGNING_CERTIFICATE)
    if ($env:LAPTOP_BRIDGE_SIGNING_PASSWORD) { $SignArgs += @("/p", $env:LAPTOP_BRIDGE_SIGNING_PASSWORD) }
    & $SignTool.Source @SignArgs $Executable
}

$Iscc = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if (-not $Iscc) { throw "Inno Setup 6 (ISCC.exe) is required to create the installer" }
& $Iscc.Source "packaging\\windows-installer.iss" "/DSourceDir=$Dist\\Laptop Bridge" "/DAppVersion=$Version"

Write-Host "Built installer in dist\\installer"

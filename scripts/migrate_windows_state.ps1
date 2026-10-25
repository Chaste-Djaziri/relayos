param(
    [Parameter(Mandatory=$true)][string]$Source,
    [string]$Python = "python"
)

$ErrorActionPreference = "Stop"
$sourcePath = (Resolve-Path -LiteralPath $Source).Path
& $Python -c "import sys; from laptop_bridge.config import migrate_state; print(migrate_state(sys.argv[1]))" -- "$sourcePath"

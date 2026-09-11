Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

foreach ($name in "HERDR_BIN_PATH", "HERDR_PANE_ID") {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is required" }
}

& $env:HERDR_BIN_PATH pane move $env:HERDR_PANE_ID `
    --new-workspace `
    --focus
exit $LASTEXITCODE

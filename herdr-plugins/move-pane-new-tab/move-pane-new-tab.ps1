Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

foreach ($name in "HERDR_BIN_PATH", "HERDR_PANE_ID", "HERDR_WORKSPACE_ID") {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is required" }
}

& $env:HERDR_BIN_PATH pane move $env:HERDR_PANE_ID `
    --new-tab `
    --workspace $env:HERDR_WORKSPACE_ID `
    --focus
exit $LASTEXITCODE

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:HERDR_PLUGIN_ENTRYPOINT_ID -eq "osc52-windows") {
    if (-not $env:COPY_TEXT) { throw "COPY_TEXT is required" }
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($env:COPY_TEXT))
    [Console]::Out.Write("$([char]27)]52;c;$payload$([char]7)")
    exit 0
}

foreach ($name in "HERDR_BIN_PATH", "HERDR_PLUGIN_ID", "HERDR_PANE_ID", "HERDR_WORKSPACE_ID") {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is required" }
}

& $env:HERDR_BIN_PATH plugin pane open `
    --plugin $env:HERDR_PLUGIN_ID `
    --entrypoint osc52-windows `
    --placement tab `
    --workspace $env:HERDR_WORKSPACE_ID `
    --env "COPY_TEXT=$($env:HERDR_PANE_ID)" `
    --no-focus
exit $LASTEXITCODE

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

foreach ($name in "HERDR_BIN_PATH", "HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID") {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is required" }
}

$tabList = (& $env:HERDR_BIN_PATH tab list --workspace $env:HERDR_WORKSPACE_ID | Out-String | ConvertFrom-Json)
$tabs = @($tabList.result.tabs | Where-Object { $_.tab_id -eq $env:HERDR_TAB_ID })
if ($tabs.Count -ne 1) { throw "tab $env:HERDR_TAB_ID was not found" }

$moveArgs = @("pane", "move", $env:HERDR_PANE_ID)
if ($tabs[0].pane_count -gt 1) {
    $moveArgs += @("--new-tab", "--workspace", $env:HERDR_WORKSPACE_ID)
} else {
    $moveArgs += "--new-workspace"
}
$moveArgs += "--focus"

& $env:HERDR_BIN_PATH @moveArgs
exit $LASTEXITCODE

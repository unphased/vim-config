[CmdletBinding()]
param(
    [ValidateSet("Auto", "Stable", "Preview", "Canary", "Unpackaged")]
    [string] $Edition = "Auto"
)

$ErrorActionPreference = "Stop"

if (-not $env:LOCALAPPDATA) {
    throw "LOCALAPPDATA is not set. Run this script from Windows PowerShell or PowerShell."
}

$settingsPaths = [ordered]@{
    Stable = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    Preview = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
    Canary = Join-Path $env:LOCALAPPDATA "Packages\Microsoft.WindowsTerminalCanary_8wekyb3d8bbwe\LocalState\settings.json"
    Unpackaged = Join-Path $env:LOCALAPPDATA "Microsoft\Windows Terminal\settings.json"
}

if ($Edition -eq "Auto") {
    $matches = @($settingsPaths.GetEnumerator() | Where-Object { Test-Path $_.Value })
    if ($matches.Count -eq 0) {
        throw "No Windows Terminal settings.json was found. Start Windows Terminal once, then rerun this script."
    }
    if ($matches.Count -gt 1) {
        $names = ($matches | ForEach-Object { $_.Key }) -join ", "
        throw "Multiple Windows Terminal editions were found ($names). Rerun with -Edition Stable, Preview, Canary, or Unpackaged."
    }
    $targetPath = $matches[0].Value
    $selectedEdition = $matches[0].Key
}
else {
    $targetPath = $settingsPaths[$Edition]
    $selectedEdition = $Edition
    if (-not (Test-Path $targetPath)) {
        throw "$Edition settings were not found at $targetPath. Start that Windows Terminal edition once, then rerun this script."
    }
}

$overridesPath = Join-Path $PSScriptRoot "portable-settings.json"
$settings = Get-Content -Raw -LiteralPath $targetPath | ConvertFrom-Json
$overrides = Get-Content -Raw -LiteralPath $overridesPath | ConvertFrom-Json

function Set-JsonProperty {
    param(
        [Parameter(Mandatory = $true)] [object] $Object,
        [Parameter(Mandatory = $true)] [string] $Name,
        [AllowNull()] [object] $Value
    )

    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

foreach ($property in $overrides.PSObject.Properties) {
    if ($property.Name -notin @("actions", "profiles")) {
        Set-JsonProperty -Object $settings -Name $property.Name -Value $property.Value
    }
}

if (-not $settings.profiles) {
    Set-JsonProperty -Object $settings -Name "profiles" -Value ([PSCustomObject]@{})
}
if (-not $settings.profiles.defaults) {
    Set-JsonProperty -Object $settings.profiles -Name "defaults" -Value ([PSCustomObject]@{})
}
foreach ($property in $overrides.profiles.defaults.PSObject.Properties) {
    Set-JsonProperty -Object $settings.profiles.defaults -Name $property.Name -Value $property.Value
}

$overrideKeys = @($overrides.actions | ForEach-Object { $_.keys } | Where-Object { $_ })
$preservedActions = @(
    $settings.actions | Where-Object {
        (-not $_.keys) -or ($_.keys -notin $overrideKeys)
    }
)
Set-JsonProperty -Object $settings -Name "actions" -Value @($preservedActions + $overrides.actions)

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = "$targetPath.$timestamp.bak"
Copy-Item -LiteralPath $targetPath -Destination $backupPath

$tempPath = "$targetPath.tmp"
$settings | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tempPath -Encoding UTF8
Move-Item -LiteralPath $tempPath -Destination $targetPath -Force

Write-Host "Updated Windows Terminal $selectedEdition settings:"
Write-Host "  $targetPath"
Write-Host "Backup:"
Write-Host "  $backupPath"

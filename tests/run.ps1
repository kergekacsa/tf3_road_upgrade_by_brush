# Compiles the mod's Teal files that the tests load and runs every *_test.lua with Lua.
# Needs the Teal compiler (see DEVELOPMENT-TOOLS.md) and `lua55` on the PATH. Set $env:TL to use another compiler path.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$tl = if ($env:TL) { $env:TL } else { 'C:\Users\Kacsa\tools\teal\tl-0.24.8-windows-x86_64\tl.exe' }
$build = Join-Path $PSScriptRoot '.build'
$modules = 'proposal_probe', 'bb_upgrade', 'brush_layer', 'bb_select', 'brush_rails', 'rub_templates', 'rub_grid_builder', 'pair_spike', 'node_crosswalks', 'crosswalk_pass', 'brush_upgrade.script'

if (Test-Path $build) { Remove-Item -Recurse -Force $build }
New-Item -ItemType Directory -Force $build | Out-Null
Push-Location $root
try {
    foreach ($module in $modules) {
        & $tl gen -o (Join-Path $build "$module.lua") "kacsa_road_upgrade_brush/content/road_upgrade_brush/$module.tl" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "tl gen failed for $module" }
    }
    $failed = 0
    foreach ($test in Get-ChildItem $PSScriptRoot -Filter '*_test.lua') {
        & lua55 $test.FullName
        if ($LASTEXITCODE -ne 0) { $failed++ }
    }
    if ($failed -gt 0) { Write-Host "$failed test file(s) failed"; exit 1 }
    Write-Host 'all test files passed'
}
finally {
    Pop-Location
}

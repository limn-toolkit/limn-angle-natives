# ASCII only: Windows PowerShell 5.1 reads a script without a byte-order mark as the ANSI code page.
#
# Builds ANGLE's libEGL.dll and libGLESv2.dll for Windows, OpenGL ES over Direct3D 11 and nothing
# else, from the commit angle.pin names, with ANGLE's own build, and stages them where the jars are
# packed from:
#
#   native\dist\limn\angle\native\windows-<arch>\{libEGL.dll,libGLESv2.dll,THIRD_PARTY.txt,BUILD-INFO.txt}
#   native\dist\limn\angle\native\LICENSE-angle.txt
#
#   pwsh scripts\build-angle.ps1 -Arch x86_64,aarch64     # both, from one x64 checkout
#
# The arm64 slice is cross-compiled on an x64 machine, which is how ANGLE's build makes it; it is
# tested on a native arm64 one. The gn arguments are scripts/gn-args.sh's, shared with macOS.
#
# What the toolkit's loader needs of a Windows library, checked on what is about to be packed:
#   - the C runtime linked in (ANGLE's build links it statically outside a component build), so no
#     Visual C++ redistributable ships: the imports name Windows' own DLLs and nothing else;
#   - libEGL importing libGLESv2.dll by that name, which the loader satisfies by loading it first.
# d3dcompiler_47.dll is loaded by name at run time and comes with Windows 10 and 11.

param([string[]] $Arch = @("x86_64"))
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
function Pin($name) { (Select-String -Path "$Root\angle.pin" -Pattern "^$name=(.*)$").Matches[0].Groups[1].Value }
$AngleBranch = Pin "ANGLE_BRANCH"
$AngleCommit = Pin "ANGLE_COMMIT"
$DepotToolsCommit = Pin "DEPOT_TOOLS_COMMIT"
$Arch = $Arch | ForEach-Object { $_ -split "," } | Where-Object { $_ }

$Work = "$Root\native\work"
$Dist = "$Root\native\dist\limn\angle\native"
New-Item -ItemType Directory -Force $Work, $Dist | Out-Null

function Run([string] $exe, [string[]] $arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$exe $($arguments -join ' ') exited with $LASTEXITCODE" }
}

# depot_tools at its pin, kept from updating itself, using the Visual Studio installed here rather
# than Google's internal toolchain package.
$env:DEPOT_TOOLS_UPDATE = "0"
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath
$env:vs2022_install = $vs
if (-not (Test-Path "$Work\depot_tools\.git")) {
    Run git @("clone", "-q", "--filter=blob:none", "https://chromium.googlesource.com/chromium/tools/depot_tools.git", "$Work\depot_tools")
}
Run git @("-C", "$Work\depot_tools", "fetch", "-q", "origin", $DepotToolsCommit)
Run git @("-C", "$Work\depot_tools", "checkout", "-q", $DepotToolsCommit)
$env:PATH = "$Work\depot_tools;$env:PATH"
# The python and the tools depot_tools runs on; with its self-update off, nothing else installs them.
Run "$Work\depot_tools\bootstrap\win_tools.bat" @()

$Angle = "$Work\angle"
if (-not (Test-Path "$Angle\.git")) {
    Run git @("init", "-q", $Angle)
    Run git @("-C", $Angle, "remote", "add", "origin", "https://chromium.googlesource.com/angle/angle")
}
Run git @("-C", $Angle, "fetch", "-q", "--depth", "1", "origin", $AngleCommit)
Run git @("-C", $Angle, "checkout", "-q", $AngleCommit)
# This repository's changes to ANGLE, each with its reason at the top, on a clean tree every time.
Run git @("-C", $Angle, "checkout", "-q", "--", ".")
Get-ChildItem "$Root\patches\*.patch" | ForEach-Object { Run git @("-C", $Angle, "apply", $_.FullName) }
Push-Location $Angle
try {
    # depot_tools' own Python, which its bootstrap installed: no Python of the machine's is needed.
    if (-not (Test-Path ".gclient")) { Run python3.bat @("scripts\bootstrap.py") }
    Run gclient.bat @("sync", "--no-history", "--shallow", "--nohooks", "-j", "8")
    Run gclient.bat @("runhooks")
} finally { Pop-Location }

Copy-Item "$Angle\LICENSE" "$Dist\LICENSE-angle.txt"
# Visual Studio's dumpbin, for the host this runs on: ANGLE's own clang ships no object reader.
$hostTools = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "Hostarm64\arm64" } else { "Hostx64\x64" }
$dumpbin = Get-ChildItem "$vs\VC\Tools\MSVC\*\bin\$hostTools\dumpbin.exe" | Select-Object -Last 1 -ExpandProperty FullName
# Git's bash by its path: a bare "bash" can resolve to the WSL launcher in System32.
$bash = "$env:ProgramFiles\Git\bin\bash.exe"

foreach ($slice in $Arch) {
    $out = "out\windows-$slice"
    Write-Host "- building ANGLE $AngleBranch ($AngleCommit) for windows-$slice"
    # Written to args.gn rather than passed as --args: Windows PowerShell 5.1 strips the quotes
    # inside an argument it hands a native program, and target_cpu="arm64" arrives as arm64.
    $gnArgs = (& $bash "$($Root -replace '\\','/')/scripts/gn-args.sh" windows $slice)
    New-Item -ItemType Directory -Force "$Angle\$out" | Out-Null
    [System.IO.File]::WriteAllLines("$Angle\$out\args.gn", [string[]]$gnArgs)
    Push-Location $Angle
    try {
        Run gn.bat @("gen", $out)
        Run autoninja.bat @("-C", $out, "libEGL", "libGLESv2")
    } finally { Pop-Location }

    $stage = "$Dist\windows-$slice"
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item "$Angle\$out\libEGL.dll", "$Angle\$out\libGLESv2.dll" $stage

    # The machine field's code, which dumpbin prints the same in every display language.
    $machine = if ($slice -eq "aarch64") { "AA64" } else { "8664" }
    foreach ($lib in "libEGL.dll", "libGLESv2.dll") {
        $file = "$stage\$lib"
        $headers = & $dumpbin /nologo /headers $file | Out-String
        if ($headers -notmatch "\b$machine\b") { throw "$file is not machine $machine" }
        $imports = & $dumpbin /nologo /dependents $file | Where-Object { $_ -match '^\s+(\S+\.dll)\s*$' } | ForEach-Object { $matches[1] }
        foreach ($import in $imports) {
            if ($import -match "^(vcruntime|msvcp|ucrtbase|api-ms-win-crt-)" -or $import -match "^(d3d9|z|libz)\.dll$") {
                throw "$lib imports $import, which a library on Maven Central cannot count on or must not need"
            }
        }
        Write-Host "ok $lib`: $machine, imports $($imports -join ', ')"
    }

    Push-Location $Angle
    try { Run python3.bat @("$Root\scripts\license_inventory.py", ".", $out, "$stage\THIRD_PARTY.txt", "libEGL", "libGLESv2") }
    finally { Pop-Location }

    $position = (Select-String -Path "$Angle\$out\gen\angle\angle_commit.h" -Pattern "ANGLE_COMMIT_POSITION (\d+)" -ErrorAction SilentlyContinue).Matches | Select-Object -First 1
    @(
        "ANGLE branch     chromium/$AngleBranch",
        "ANGLE commit     $AngleCommit",
        "depot_tools      $DepotToolsCommit",
        "built            $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) on $((Get-CimInstance Win32_OperatingSystem).Caption)",
        "compiler         $((& "$Angle\third_party\llvm-build\Release+Asserts\bin\clang-cl.exe" --version)[0])",
        "commit position  $(if ($position) { $position.Groups[1].Value })",
        "gn args"
    ) + ((& $bash "$($Root -replace '\\','/')/scripts/gn-args.sh" windows $slice) | ForEach-Object { "  $_" }) |
        Set-Content -Encoding utf8 "$stage\BUILD-INFO.txt"
    Get-ChildItem $stage | ForEach-Object { "{0,-18} {1,12:N0}" -f $_.Name, $_.Length }
}

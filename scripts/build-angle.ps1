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

$Angle = "$Work\angle"
if (-not (Test-Path "$Angle\.git")) {
    Run git @("init", "-q", $Angle)
    Run git @("-C", $Angle, "remote", "add", "origin", "https://chromium.googlesource.com/angle/angle")
}
Run git @("-C", $Angle, "fetch", "-q", "--depth", "1", "origin", $AngleCommit)
Run git @("-C", $Angle, "checkout", "-q", $AngleCommit)
Push-Location $Angle
try {
    if (-not (Test-Path ".gclient")) { Run python @("scripts\bootstrap.py") }
    Run gclient.bat @("sync", "--no-history", "--shallow", "--nohooks", "-j", "8")
    Run gclient.bat @("runhooks")
} finally { Pop-Location }

Copy-Item "$Angle\LICENSE" "$Dist\LICENSE-angle.txt"
$readobj = "$Angle\third_party\llvm-build\Release+Asserts\bin\llvm-readobj.exe"
# Git's bash by its path: a bare "bash" can resolve to the WSL launcher in System32.
$bash = "$env:ProgramFiles\Git\bin\bash.exe"

foreach ($slice in $Arch) {
    $out = "out\windows-$slice"
    Write-Host "· building ANGLE $AngleBranch ($AngleCommit) for windows-$slice"
    $gnArgs = (& $bash "$($Root -replace '\\','/')/scripts/gn-args.sh" windows $slice) -join " "
    Push-Location $Angle
    try {
        Run gn.bat @("gen", $out, "--args=$gnArgs")
        Run autoninja.bat @("-C", $out, "libEGL", "libGLESv2")
    } finally { Pop-Location }

    $stage = "$Dist\windows-$slice"
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item "$Angle\$out\libEGL.dll", "$Angle\$out\libGLESv2.dll" $stage

    $machine = if ($slice -eq "aarch64") { "ARM64" } else { "AMD64" }
    foreach ($lib in "libEGL.dll", "libGLESv2.dll") {
        $file = "$stage\$lib"
        $headers = & $readobj --file-headers $file | Out-String
        if ($headers -notmatch "IMAGE_FILE_MACHINE_$machine") { throw "$file is not $machine" }
        $imports = & $readobj --coff-imports $file | Select-String "Name: (\S+\.dll)" | ForEach-Object { $_.Matches[0].Groups[1].Value }
        foreach ($import in $imports) {
            if ($import -match "^(vcruntime|msvcp|ucrtbase|api-ms-win-crt-)" -or $import -match "^(d3d9|z|libz)\.dll$") {
                throw "$lib imports $import, which a library on Maven Central cannot count on or must not need"
            }
        }
        Write-Host "✓ $lib`: $machine, imports $($imports -join ', ')"
    }

    Push-Location $Angle
    try { Run python @("$Root\scripts\license_inventory.py", ".", $out, "$stage\THIRD_PARTY.txt", "libEGL", "libGLESv2") }
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

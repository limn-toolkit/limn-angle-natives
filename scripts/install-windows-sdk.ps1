# ASCII only: Windows PowerShell 5.1 reads a script without a byte-order mark as the ANSI code page.
#
# Installs the Windows SDK the pinned ANGLE builds against, with what its build copies out of it,
# on a machine that has Visual Studio's C++ tools but not that SDK (GitHub's Windows runners):
#
#   pwsh scripts\install-windows-sdk.ps1
#
# The version is the one ANGLE's own build/toolchain/win/setup_toolchain.py names (SDK_VERSION),
# and gn refuses any other. Besides headers and libraries, the build copies dbghelp.dll from the
# SDK's "Debugging Tools for Windows" for every CPU it targets (x64 and arm64), and the SDK's
# installer puts in only the host's: the other CPU's debuggers are unpacked from the installer's
# own package, which it leaves in the package cache, without installing anything else.
#
# Needs an elevated shell and winget. Does nothing for a part already present.

param([string] $Version = "10.0.28000")
$ErrorActionPreference = "Stop"
$Kits = "${env:ProgramFiles(x86)}\Windows Kits\10"

if (-not (Test-Path "$Kits\Include\$Version.0\um")) {
    winget install --id "Microsoft.WindowsSDK.$Version" -e --silent --accept-package-agreements `
        --accept-source-agreements --disable-interactivity --override "/features + /quiet /norestart"
    if (-not (Test-Path "$Kits\Include\$Version.0\um")) { throw "the Windows SDK $Version did not install" }
}

foreach ($cpu in @("x64", "arm64")) {
    $dest = "$Kits\Debuggers\$cpu"
    if (Test-Path "$dest\dbghelp.dll") { "debuggers ${cpu}: present"; continue }
    $msi = Get-ChildItem "$env:ProgramData\Package Cache" -Recurse -Filter "*Debuggers And Tools-${cpu}_*.msi" `
            -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like "*v10.1.$($Version.Split('.')[2]).*" } |
            Select-Object -First 1
    if (-not $msi) { throw "no debuggers package for $cpu in the package cache of the SDK $Version" }
    $unpacked = "$env:TEMP\debuggers-$cpu"
    Remove-Item -Recurse -Force $unpacked -ErrorAction SilentlyContinue
    Start-Process msiexec -ArgumentList "/a `"$($msi.FullName)`" /qn TARGETDIR=`"$unpacked`"" -Wait
    $dbghelp = Get-ChildItem $unpacked -Recurse -Filter dbghelp.dll | Where-Object { $_.DirectoryName -like "*\$cpu" } |
            Select-Object -First 1
    if (-not $dbghelp) { throw "the debuggers package for $cpu holds no dbghelp.dll" }
    New-Item -ItemType Directory -Force $dest | Out-Null
    Copy-Item -Recurse -Force (Join-Path $dbghelp.DirectoryName "*") $dest
    "debuggers ${cpu}: unpacked from $($msi.Name)"
}

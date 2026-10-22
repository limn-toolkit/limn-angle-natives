# limn-angle-natives

The OpenGL ES 3.0 implementation the [Limn toolkit](https://github.com/limn-toolkit/limn-toolkit)
falls back to when a machine's own OpenGL gives a window no context: ANGLE, built with only its
Direct3D 11 backend for Windows and only its Metal backend for macOS, on x86_64 and aarch64.

```
io.github.limn-toolkit:limn-angle-natives:2.1.8078.0                            licence only
io.github.limn-toolkit:limn-angle-natives:2.1.8078.0:natives-windows-x86_64     libEGL.dll, libGLESv2.dll
io.github.limn-toolkit:limn-angle-natives:2.1.8078.0:natives-windows-aarch64
io.github.limn-toolkit:limn-angle-natives:2.1.8078.0:natives-macos-x86_64       libEGL.dylib, libGLESv2.dylib
io.github.limn-toolkit:limn-angle-natives:2.1.8078.0:natives-macos-aarch64
```

An application does not name this artifact: the toolkit's backend does, and loads it only on the
machines that need it — a Windows machine with no OpenGL driver, or one older than 3.3, and a Mac
with no accelerated OpenGL renderer or no OpenGL at all. Everywhere else the libraries are never
loaded. Linux has no classifier, because Mesa already gives every Linux machine an OpenGL the
toolkit runs on. See the toolkit's ADR 003 for why, and ADR 078 for this repository.

## Versions

`2.1.<branch>.<n>`: 2.1 is ANGLE's own version, `<branch>` the Chromium release branch ANGLE is taken
from (`angle.pin`), and `<n>` this repository's packaging. The commit and how each library was built
are in `BUILD-INFO.txt` in its jar.

## What is inside, and its licences

ANGLE is BSD-3-Clause. Each platform's jar carries `THIRD_PARTY.txt`: every source file compiled
into its two libraries, grouped by the directory that states its licence, with the full text of
each licence. The build refuses a licence it does not recognise as one a library may redistribute.
The libraries need nothing from Microsoft or Apple beyond what Windows 10 and 11 and macOS 11 carry
(`d3dcompiler_47.dll` comes with Windows); the C and C++ runtimes are linked in.

## Building

```
scripts/build-angle.sh --arch arm64,x86_64          # macOS
pwsh scripts/build-angle.ps1 -Arch x86_64,aarch64   # Windows
./gradlew test                                      # a context through what this machine built
bash scripts/rehearse-consumer.sh                   # resolve the jars as a consumer would
```

On macOS the build needs Xcode's Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`
on Xcode 26 and later). A first build fetches several gigabytes and takes hours of CPU; the `natives` workflow is where it
is meant to run. See [RELEASING.md](RELEASING.md) for releases.

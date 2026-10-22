#!/usr/bin/env bash
#
# Builds ANGLE's libEGL and libGLESv2 for macOS, OpenGL ES over Metal and nothing else, from the
# commit angle.pin names, with ANGLE's own build, and stages them where the jars are packed from:
#
#   native/dist/limn/angle/native/macos-<arch>/{libEGL.dylib,libGLESv2.dylib,THIRD_PARTY.txt,BUILD-INFO.txt}
#   native/dist/limn/angle/native/LICENSE-angle.txt
#
#   scripts/build-angle.sh                         # this Mac's architecture
#   scripts/build-angle.sh --arch arm64,x86_64     # both, from one checkout (what a release does)
#
# Windows is scripts/build-angle.ps1; the arguments both use are scripts/gn-args.sh.
#
# Hours of CPU and several gigabytes of checkout on a first run: this is what the natives workflow
# runs on GitHub's runners, and not something to start on a laptop without meaning to.
#
# What the toolkit's loader needs of a macOS library, and this script makes true and then checks:
#   - an install name that is the bare file name (libEGL.dylib, libGLESv2.dylib): the windowing
#     library opens libEGL by that name, and macOS answers it with an image already loaded under
#     it, which is how the loader hands it the copy it loaded by full path;
#   - nothing linked but the system's frameworks and libraries (and libGLESv2, by that same name);
#   - a minimum macOS of 11.0, Limn's floor.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pin() { sed -n "s/^$1=\(.*\)$/\1/p" "$ROOT/angle.pin"; }
ANGLE_BRANCH="$(pin ANGLE_BRANCH)"
ANGLE_COMMIT="$(pin ANGLE_COMMIT)"
DEPOT_TOOLS_COMMIT="$(pin DEPOT_TOOLS_COMMIT)"

ARCHS="$(uname -m)"
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCHS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ "$(uname -s)" = Darwin ] || { echo "this script builds the macOS slices; Windows is build-angle.ps1" >&2; exit 1; }

WORK="$ROOT/native/work"
DIST="$ROOT/native/dist/limn/angle/native"
mkdir -p "$WORK" "$DIST"

# depot_tools at its pin, kept from updating itself.
export DEPOT_TOOLS_UPDATE=0
if [ ! -d "$WORK/depot_tools/.git" ]; then
  git clone -q --filter=blob:none https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"
fi
git -C "$WORK/depot_tools" fetch -q origin "$DEPOT_TOOLS_COMMIT"
git -C "$WORK/depot_tools" checkout -q "$DEPOT_TOOLS_COMMIT"
export PATH="$WORK/depot_tools:$PATH"

# ANGLE at its pin, and its dependencies at the revisions its DEPS names.
ANGLE="$WORK/angle"
if [ ! -d "$ANGLE/.git" ]; then
  git init -q "$ANGLE"
  git -C "$ANGLE" remote add origin https://chromium.googlesource.com/angle/angle
fi
git -C "$ANGLE" fetch -q --depth 1 origin "$ANGLE_COMMIT"
git -C "$ANGLE" checkout -q "$ANGLE_COMMIT"
( cd "$ANGLE" && [ -f .gclient ] || python3 scripts/bootstrap.py )
( cd "$ANGLE" && gclient sync --no-history --shallow --nohooks -j 8 && gclient runhooks )

cp "$ANGLE/LICENSE" "$DIST/LICENSE-angle.txt"

for arch in ${ARCHS//,/ }; do
  case "$arch" in
    arm64|aarch64) slice=aarch64; lipo_arch=arm64 ;;
    x86_64|x64) slice=x86_64; lipo_arch=x86_64 ;;
    *) echo "unknown architecture: $arch" >&2; exit 1 ;;
  esac
  out="out/macos-$slice"
  echo "· building ANGLE $ANGLE_BRANCH ($ANGLE_COMMIT) for macos-$slice"
  ( cd "$ANGLE" && gn gen "$out" --args="$(bash "$ROOT/scripts/gn-args.sh" macos "$slice" | tr '\n' ' ')" \
      && autoninja -C "$out" libEGL libGLESv2 )

  stage="$DIST/macos-$slice"
  rm -rf "$stage"; mkdir -p "$stage"
  cp "$ANGLE/$out/libEGL.dylib" "$ANGLE/$out/libGLESv2.dylib" "$stage/"
  for lib in libEGL libGLESv2; do
    file="$stage/$lib.dylib"
    install_name_tool -id "$lib.dylib" "$file"
    # A reference from libEGL to libGLESv2, whatever the build called it, becomes the bare name.
    for dep in $(otool -L "$file" | tail -n +2 | awk '{print $1}' | grep 'libGLESv2.dylib$' || true); do
      install_name_tool -change "$dep" libGLESv2.dylib "$file"
    done
    codesign --force --sign - "$file"
  done

  # The checks, on what is about to be packed rather than on what was meant.
  for lib in libEGL libGLESv2; do
    file="$stage/$lib.dylib"
    [ "$(lipo -archs "$file")" = "$lipo_arch" ] || { echo "✗ $file is $(lipo -archs "$file"), not $lipo_arch" >&2; exit 1; }
    [ "$(otool -D "$file" | tail -1)" = "$lib.dylib" ] || { echo "✗ $file has install name $(otool -D "$file" | tail -1)" >&2; exit 1; }
    otool -L "$file" | tail -n +2 | awk '{print $1}' | while read -r dep; do
      case "$dep" in
        /System/Library/*|/usr/lib/*|libGLESv2.dylib|"$lib.dylib") ;;
        *) echo "✗ $file links $dep, which macOS does not provide" >&2; exit 1 ;;
      esac
    done
    minos="$(otool -l "$file" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
    [ "$minos" = "11.0" ] || { echo "✗ $file needs macOS $minos; Limn's floor is 11.0" >&2; exit 1; }
    echo "✓ $lib.dylib: $lipo_arch, install name $lib.dylib, system libraries only, macOS $minos"
  done

  ( cd "$ANGLE" && python3 "$ROOT/scripts/license_inventory.py" . "$out" "$stage/THIRD_PARTY.txt" libEGL libGLESv2 )
  {
    echo "ANGLE branch     chromium/$ANGLE_BRANCH"
    echo "ANGLE commit     $ANGLE_COMMIT"
    echo "depot_tools      $DEPOT_TOOLS_COMMIT"
    echo "built            $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(sw_vers -productName) $(sw_vers -productVersion)"
    echo "compiler         $("$ANGLE/third_party/llvm-build/Release+Asserts/bin/clang" --version | head -1)"
    echo "commit position  $(sed -n 's/.*ANGLE_COMMIT_POSITION \([0-9]*\).*/\1/p' "$ANGLE/$out/gen/angle/angle_commit.h" 2>/dev/null)"
    echo "gn args"
    bash "$ROOT/scripts/gn-args.sh" macos "$slice" | sed 's/^/  /'
  } > "$stage/BUILD-INFO.txt"
  ls -l "$stage"
done

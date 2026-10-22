#!/usr/bin/env bash
#
# Prints the gn arguments of one slice. Shared by build-angle.sh (macOS) and build-angle.ps1
# (Windows, which runs it through Git's bash) so that the two platforms cannot drift on what is
# left out.
#
#   scripts/gn-args.sh <macos|windows> <x86_64|aarch64>
#
# What is built is the smallest ANGLE that gives Limn an OpenGL ES 3.0 context: the one backend the
# platform needs (Direct3D 11 on Windows, Metal on macOS) and nothing else: no Vulkan, no desktop
# OpenGL backend, no SwiftShader, no WebGPU, no OpenCL, no null backend, no tests, no capture, and
# no Perfetto tracing (which also brought protobuf, and a licence field the inventory refused).

set -euo pipefail

os="$1"
arch="$2"
case "$arch" in
  x86_64) cpu=x64 ;;
  aarch64) cpu=arm64 ;;
  *) echo "unknown architecture: $arch" >&2; exit 1 ;;
esac

cat <<ARGS
is_debug=false
is_component_build=false
is_official_build=false
symbol_level=0
target_cpu="$cpu"
angle_build_tests=false
angle_has_frame_capture=false
angle_has_histograms=false
angle_enable_cl=false
angle_enable_gl=false
angle_enable_vulkan=false
angle_enable_swiftshader=false
angle_enable_wgpu=false
angle_enable_null=false
angle_enable_perfetto=false
ARGS

case "$os" in
  windows)
    cat <<ARGS
target_os="win"
angle_enable_d3d11=true
ARGS
    ;;
  macos)
    # Limn's macOS floor is 11.0 (the toolkit's OsFloorsTest reads it from every native it ships),
    # and the toolchain's default is newer: both numbers are set, and build-angle.sh refuses a
    # library whose load command says otherwise.
    cat <<ARGS
target_os="mac"
angle_enable_metal=true
mac_deployment_target="11.0"
mac_min_system_version="11.0"
ARGS
    ;;
  *) echo "unknown os: $os" >&2; exit 1 ;;
esac

#!/usr/bin/env sh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
package_root="$project_root/dist/flaten-deploy"
binary_path="$project_root/zig-out/bin/flaten-core"
wrapper_path_src="$project_root/zig-out/bin/flaten"
libs_src="$project_root/zig-out/lib/sherpa-onnx"
sherpa_license_src="$project_root/third_party/sherpa-onnx/LICENSE.sherpa-onnx"

# Ensure Zig uses a writable cache directory before any `zig` invocations.
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-"$project_root/.zig-cache"}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-"$project_root/.zig-cache/global"}"
mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"

supported_target_hints="x86_64-linux-gnu aarch64-linux-gnu x86_64-linux aarch64-linux arm64-linux x86-linux"

usage() {
  cat <<EOF
Usage: package_release.sh [--target TRIPLE] [--output DIR]
  --target TRIPLE  zig target triple, e.g. x86_64-linux-gnu (default: auto-detected host)
                   Supported hints: $supported_target_hints. Run 'zig targets' (or pipe to
                   'rg -F <arch>') to explore the full set of valid triples.
  --output DIR     custom staging directory (default: dist/flaten-deploy-<TARGET>)
EOF
}

print_supported_target_hint() {
  cat <<EOF >&2
Supported target hints: $supported_target_hints
Run 'zig targets' (or pipe to 'rg -F <arch>') to explore the full set of valid triples.
EOF
}

validate_target_triple() {
  case "$1" in
    # Short aliases we explicitly support.
    x86-linux|x86_64-linux|aarch64-linux|arm64-linux)
      return
      ;;
    # Common full triples we know are valid even if `zig targets` is unavailable.
    x86_64-linux-gnu|aarch64-linux-gnu)
      return
      ;;
  esac
  zig_targets_output="$(zig targets 2>/dev/null || true)"
  if [ -n "$zig_targets_output" ] && printf '%s\n' "$zig_targets_output" | grep -Fq "\"$1\""; then
    return
  fi

  printf 'Unsupported --target value: %s\n' "$1" >&2
  print_supported_target_hint
  exit 1
}

dest_override=""
target_triple=""
zig_build_target=""
package_suffix=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      shift
      target_triple="$1"
      ;;
    --output)
      shift
      dest_override="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

[ -n "$target_triple" ] && validate_target_triple "$target_triple"

[ -z "$target_triple" ] && {
  # Auto-detect host target via `zig env`. Prefer a concrete Zig triple; if
  # that fails, synthesize a host-like suffix from uname, but still use Zig's
  # default "native" build target internally.
  zig_env_output="$(
    ZIG_LOCAL_CACHE_DIR="$ZIG_LOCAL_CACHE_DIR" \
    ZIG_GLOBAL_CACHE_DIR="$ZIG_GLOBAL_CACHE_DIR" \
    zig env 2>/dev/null || true
  )"
  host_target="$(
    printf '%s\n' "$zig_env_output" |
      sed -n 's/.*"target"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
      head -n 1
  )"

  if [ -n "$host_target" ]; then
    # Use Zig's host target for build, but normalize the package suffix by
    # stripping ABI details like "-gnu" etc., e.g. x86_64-linux-gnu -> x86_64-linux.
    zig_build_target="$host_target"
    case "$host_target" in
      *-linux-gnu)
        package_suffix="${host_target%-gnu}"
        ;;
      *)
        package_suffix="$host_target"
        ;;
    esac
  else
    # Fallback: derive a normalized suffix from host arch/OS using `uname`,
    # and rely on Zig's default "native" target for the actual build.
    raw_arch="$(uname -m 2>/dev/null || echo unknown-arch)"
    raw_os="$(uname -s 2>/dev/null || echo unknown-os)"

    # Normalize arch
    case "$raw_arch" in
      x86_64|amd64)
        norm_arch="x86_64"
        ;;
      i386|i686)
        norm_arch="x86"
        ;;
      arm64|aarch64)
        norm_arch="aarch64"
        ;;
      *)
        norm_arch="$raw_arch"
        ;;
    esac

    # Normalize OS
    case "$raw_os" in
      Linux)
        norm_os="linux"
        ;;
      Darwin)
        norm_os="darwin"
        ;;
      *)
        norm_os="$(printf '%s' "$raw_os" | tr '[:upper:]' '[:lower:]')"
        ;;
    esac


    if [ "$norm_os" = "darwin" ] && [ "$raw_arch" = "arm64" ]; then
      norm_arch="arm64"
    fi

    package_suffix="${norm_arch}-${norm_os}"
  fi
}

# If user specified a target, normalize it for both Zig and the package name.
if [ -n "$target_triple" ]; then
  case "$target_triple" in
    x86-linux|x86_64-linux)
      zig_build_target="x86_64-linux-gnu"
      package_suffix="x86_64-linux"
      ;;
    aarch64-linux|arm64-linux)
      zig_build_target="aarch64-linux-gnu"
      package_suffix="aarch64-linux"
      ;;
    *)
      zig_build_target="$target_triple"
      case "$target_triple" in
        *-linux-gnu)
          package_suffix="${target_triple%-gnu}"
          ;;
        *)
          package_suffix="$target_triple"
          ;;
      esac
      ;;
  esac
fi

if [ -n "$package_suffix" ]; then
  package_root="$project_root/dist/flaten-deploy-$package_suffix"
fi

if [ -n "$dest_override" ]; then
  package_root="$dest_override"
fi

echo "Building release binary..."
cd "$project_root"

build_args="-Doptimize=ReleaseFast"
[ -n "$zig_build_target" ] && build_args="$build_args -Dtarget=$zig_build_target"

[ -x "$(command -v ffmpeg 2>/dev/null)" ] || {
  echo "ffmpeg not found; install it (e.g. brew install ffmpeg) before packaging." >&2
  exit 1
}

zig build $build_args

[ -f "$binary_path" ] || {
  echo "Release binary not found at $binary_path" >&2
  exit 1
}

[ -f "$wrapper_path_src" ] || {
  echo "Wrapper binary not found at $wrapper_path_src" >&2
  exit 1
}

[ -d "$libs_src" ] || {
  echo "Sherpa libs not found at $libs_src" >&2
  exit 1
}

[ -f "$sherpa_license_src" ] || {
  echo "Sherpa license not found at $sherpa_license_src" >&2
  exit 1
}

rm -rf "$package_root"
mkdir -p "$package_root/bin" "$package_root/lib"
cp "$binary_path" "$package_root/bin/"
cp "$wrapper_path_src" "$package_root/"
cp -R "$libs_src" "$package_root/lib/"
cp "$sherpa_license_src" "$package_root/THIRD_PARTY_LICENSE_sherpa-onnx"

cat <<'EOF' >"$package_root/README.md"
# flaten

This directory contains a pre-built distribution of **flaten**, a command-line tool
for turning video or audio files into subtitle files using offline speech recognition.

## What flaten does

- Decodes input media with `ffmpeg` into mono 16 kHz PCM audio.
- Segments long audio into manageable chunks.
- Runs speech recognition via sherpa-onnx / onnxruntime.
- Writes human-readable subtitle files (e.g. SRT).

## Layout

- `flaten` – launcher binary at the package root; checks that `ffmpeg` is available,
  then dispatches to the core binary.
- `bin/flaten-core` – core CLI that performs the transcription pipeline.
- `lib/sherpa-onnx` – bundled dynamic libraries for sherpa-onnx and onnxruntime.

## Requirements

- `ffmpeg` must be installed on the target machine and visible on `PATH`.
- Network access is required if you want flaten to auto-download models on first run, otherwise you must provide models manually.

## Models

- On startup, flaten first checks `SHERPA_MODEL_DIR`; if set, that directory is used as the model root.
- If `SHERPA_MODEL_DIR` is not set and a complete model already exists in `./sherpa-model` (the legacy default), flaten will use it for that run and print a notice suggesting migration to `~/.flaten/sherpa-model`.
- In all other cases, flaten will download a default small zh/en sherpa-onnx model into `~/.flaten/sherpa-model` in the user’s home directory when internet access is available.
- For offline environments, you can pre-populate `~/.flaten/sherpa-model` and/or point `SHERPA_MODEL_DIR` to an existing sherpa-onnx model.

## Quick start

```sh
export SHERPA_MODEL_DIR=/path/to/your/model
./flaten --input some-video.mp4 --output subtitles.srt
```

EOF

echo "Package written to: $package_root"

#!/usr/bin/env sh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
package_root="$project_root/dist/flaten-deploy"
binary_path="$project_root/zig-out/bin/flaten-core"
wrapper_path_src="$project_root/zig-out/bin/flaten"
libs_src="$project_root/zig-out/lib/sherpa-onnx"

usage() {
  cat <<'EOF'
Usage: package_release.sh [--target TRIPLE] [--output DIR]
  --target TRIPLE  zig target triple, e.g. x86_64-linux-gnu (default: host)
  --output DIR     custom staging directory (default: dist/flaten-deploy[-TRIPLE])
EOF
}

dest_override=""
target_triple=""
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

[ -x "$(command -v ffmpeg 2>/dev/null)" ] || {
  echo "ffmpeg not found; install it (e.g. brew install ffmpeg) before packaging." >&2
  exit 1
}

if [ -n "$target_triple" ]; then
  package_root="$project_root/dist/flaten-deploy-$target_triple"
fi

if [ -n "$dest_override" ]; then
  package_root="$dest_override"
fi

echo "Building release binary..."
cd "$project_root"
export ZIG_LOCAL_CACHE_DIR="$project_root/.zig-cache"
export ZIG_GLOBAL_CACHE_DIR="$project_root/.zig-cache/global"
mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"

build_args="-Doptimize=ReleaseFast"
if [ -n "$target_triple" ]; then
  build_args="$build_args -Dtarget=$target_triple"
fi

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

rm -rf "$package_root"
mkdir -p "$package_root/bin" "$package_root/lib"
cp "$binary_path" "$package_root/bin/"
cp "$wrapper_path_src" "$package_root/"
cp -R "$libs_src" "$package_root/lib/"

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
- If `SHERPA_MODEL_DIR` is not set, flaten will download a default small zh/en sherpa-onnx model into a local directory (relative to the current working directory) when internet access is available.
- For offline environments, you can pre-populate the model directory and/or point `SHERPA_MODEL_DIR` to an existing sherpa-onnx model.

## Quick start

```sh
export SHERPA_MODEL_DIR=/path/to/your/model
./flaten --input some-video.mp4 --output subtitles.srt
```

EOF

echo "Package written to: $package_root"

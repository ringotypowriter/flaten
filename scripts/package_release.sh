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
- # flaten 打包说明

- 外层启动器：`flaten`（二进制，位于包根），会先检查 ffmpeg 是否可用，再调用核心二进制。
- 核心二进制：`bin/flaten-core`。
- 依赖库：`lib/sherpa-onnx` 下包含 sherpa-onnx 与 onnxruntime 的动态库，rpath 已配置。
- 模型：不捆绑模型，你可以在目标机上设置 `SHERPA_MODEL_DIR` 指向已有模型目录。
- 运行要求：目标机需安装 ffmpeg（例如 `brew install ffmpeg`），并保持 `PATH` 可见。

## 运行

```sh
export SHERPA_MODEL_DIR=/path/to/your/model
# 推荐：带检查的入口（二进制，包根）
./flaten --input some-video.mp4 --output subtitles.srt

# 或直接调用核心二进制（不检查 ffmpeg）
./bin/flaten-core --input some-video.mp4 --output subtitles.srt
```

## 说明
- `zig-out/bin/flaten` 已在发布期间构建为 ReleaseFast。
- `lib/sherpa-onnx` 目录是通过 Zig 的 install 步骤整理出来的，保证了动态库与二进制在一个包内部。
EOF

echo "打包完成：$package_root"

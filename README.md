# flaten – Speech-Only Subtitle Generator (Zig + sherpa-onnx)

`flaten` is a small CLI tool written in Zig that takes a video or audio file, extracts the speech-only portions, runs ASR using **sherpa-onnx**, and writes an `.srt` subtitle file aligned to the **original timeline** (including silences that were skipped during recognition).

The project is test‑driven and keeps all heavy dependencies behind clear module boundaries to make local iteration fast and reliable.

---

## Features

- **End-to-end pipeline**
  - `ffmpeg` → raw mono PCM (`s16le`, 16 kHz)
  - Voice Activity Detection (VAD) on the original timeline
  - Per-segment ASR via sherpa-onnx (with a lightweight test stub)
  - SRT generation that preserves the original media timestamps

- **VAD tuned for speech segments**
  - Energy-based frame analysis with:
    - `min_speech_ms`: minimum duration for a valid speech segment
    - `min_silence_ms`: short silences *inside* speech do **not** split segments
  - Simple tests that validate “silence–speech–silence” and “short blip ignored” behavior.

- **Sherpa-onnx integration**
  - Model management module that can:
    - Use a user-specified model dir (`SHERPA_MODEL_DIR`)
    - Or auto-download a default zipformer zh-en model into `sherpa-model/`
  - In test builds, ASR is stubbed (`"hello (stub)"`) so tests never depend on real models or network.

- **Clean separation of modules**
  - `subtitle_writer.zig`: SRT formatting utilities
  - `cli_options.zig`: CLI parsing and defaults
  - `audio_segmenter.zig`: VAD / speech segment detection
  - `ffmpeg_adapter.zig`: builds `ffmpeg` argv for PCM extraction
  - `model_manager.zig`: model directory + download logic
  - `asr_sherpa.zig`: sherpa-onnx wrapper and audio prep (WAV or raw PCM)
  - `pipeline.zig`: `transcribe_video_to_srt` and SRT time-line stitching
  - `main.zig`: CLI entrypoint

---

## Requirements

- **Zig**: 0.15.x (project is developed and tested with 0.15.2); required only if you build from source or extend the project.
- **ffmpeg**: installed on the system and accessible on `PATH`
- **sherpa-onnx**:
  - C API headers and libraries present under:
    - `third_party/sherpa-onnx/v1.12.17/macos-universal/include`
    - `third_party/sherpa-onnx/v1.12.17/macos-universal/lib`
  - The `build.zig` file wires the include/library paths and links sherpa-onnx / onnxruntime.
- **A sherpa-onnx model**:
  - By default, `model_manager.zig` will attempt to download a small zh-en zipformer model into `sherpa-model/`.
  - You can override this with `SHERPA_MODEL_DIR` if you already have models.

On macOS with Homebrew you might have something like:

```bash
brew install zig ffmpeg
```

and then place the sherpa-onnx release in `third_party/sherpa-onnx/...` as expected by `build.zig`.

### Linux ffmpeg installation

On Linux, ffmpeg is usually available via the distribution package manager:

```bash
sudo apt update && sudo apt install ffmpeg          # Debian / Ubuntu
sudo dnf install ffmpeg                             # Fedora / RHEL
sudo pacman -Sy ffmpeg                              # Arch
```

You can also use `snap install ffmpeg` or a `flatpak` build if those are provided by your distro. Once installed, ensure `ffmpeg` is on `PATH` before running `flaten`.

---

## Building and Running

### Local dev

```bash
zig build run -- --input path/to/input.mp4 --output output.srt
```

CLI flags (parsed in `src/cli_options.zig`):

- `--input` / `-i` (required): path to the input video/audio file.
- `--output` / `-o` (optional): path to the output `.srt` file.
  - If omitted, the extension of the input file is replaced with `.srt` (e.g. `video.mp4` → `video.srt`).
- `--sample-rate` (optional, default `16000`): currently the pipeline expects 16 kHz and will reject others.
- `--min-speech-ms` (optional, default `300`): minimum speech segment duration (ms).
- `--min-silence-ms` (optional, default `200`): short silences below this duration will *not* split segments.

Example:

```bash
zig build run -- \
  --input test_resources/test.mp4 \
  --output out.srt \
  --min-speech-ms 300 \
  --min-silence-ms 200
```

### Packaged artifacts (dist/flaten-deploy)

`./scripts/package_release.sh` produces a deployable folder:

```
flaten             # wrapper at package root, checks ffmpeg then runs bin/flaten-core
bin/flaten-core    # real CLI
lib/sherpa-onnx/   # bundled sherpa-onnx + onnxruntime libs (rpath ready)
README.md
```

Run on the target machine (ffmpeg must be installed):

```bash
export SHERPA_MODEL_DIR=/path/to/model
./flaten --input video.mp4 --output subtitles.srt
```

If you want to skip the ffmpeg check, call the core directly:

```bash
./bin/flaten-core --input video.mp4 --output subtitles.srt
```

You can cross-compile and package in one step by passing a target triple; the
staging directory will include the target in its name:

```bash
./scripts/package_release.sh --target x86_64-linux-gnu
# output: dist/flaten-deploy-x86_64-linux-gnu/...
```

### Using release artifacts directly

You can skip building entirely by downloading the `dist/flaten-deploy-*` bundle from GitHub Releases. Each release bundle already includes:

- `flaten` launcher
- `bin/flaten-core`
- `lib/sherpa-onnx` dynamic libraries
- `THIRD_PARTY_LICENSE_sherpa-onnx`

These binaries only require a host `ffmpeg` executable and a sherpa-onnx model directory; no Zig toolchain is needed on the machine where you run `flaten`. Zig is only a build-time dependency for creating or modifying the binaries.

### Cross-compiling (e.g., macOS → Linux x86_64)

Zig can cross-compile out of the box, but you must provide target-side deps:

- **sherpa-onnx / onnxruntime**: this repo already ships `third_party/sherpa-onnx/v1.12.17/linux-x86_64/`, and `build.zig` will pick it when `-Dtarget=x86_64-linux-gnu` is set.
- **ffmpeg**: you need the target platform’s pkg-config files and shared libs (`*.pc` + `.so`). Point `PKG_CONFIG_PATH` to that ffmpeg’s `lib/pkgconfig`.

Example (build Linux x86_64 Release on macOS):

```bash
export PKG_CONFIG_PATH=/path/to/linux-ffmpeg/lib/pkgconfig
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast -p dist/linux-x86_64
```

Artifacts land under `dist/linux-x86_64/zig-out/{bin,lib}`; then package them the same way (root wrapper, `bin/flaten-core`, `lib/sherpa-onnx`).

---

## Testing

The project is designed to be test-first. Core modules have unit tests that do **not** depend on network or heavy models:

- `subtitle_writer.zig`
- `cli_options.zig`
- `audio_segmenter.zig`
- `ffmpeg_adapter.zig`
- `model_manager.zig`
- `asr_sherpa.zig` (uses a stub in `zig test`)
- `pipeline.zig` (includes a small end-to-end test with `test_resources/test.mp4`)

Run all tests:

```bash
zig build test
```

Notes:

- `asr_sherpa.zig` tests use a stub that returns `"hello (stub)"` and do not require real models.
- The integration test in `pipeline.zig` calls `transcribe_video_to_srt` on `test_resources/test.mp4` and only checks basic SRT structure plus that the pipeline completes.

---

## Architecture Overview

### VAD (`audio_segmenter.zig`)

- Works on raw PCM16 (`[]const i16`) at a given sample rate.
- Splits audio into fixed-size frames (default 20 ms), computes a simple energy measure per frame, and marks frames as voiced/unvoiced via `energy_threshold`.
- Key configuration:
  - `min_speech_ms`: total voiced duration must exceed this to produce a segment.
  - `min_silence_ms`: within an ongoing speech segment, silence shorter than this will **not** end the segment; longer silence causes the segment to close.
- Returns an array of:

```zig
pub const SpeechSegment = struct {
    start_ms: u64, // on the original timeline
    end_ms: u64,
};
```

These timestamps always refer to the original media timeline (including silences).

### ASR (`asr_sherpa.zig`)

- Wraps sherpa-onnx C API:
  - prepares audio (WAV parsing, PCM→mono, resampling),
  - configures an offline recognizer,
  - returns `[]SegmentResult{ start_ms, end_ms, text }`.
- Two entrypoints:
  - `recognize`:
    - In test builds (`builtin.is_test`), returns a stub `"hello (stub)"`.
    - In normal builds, delegates to `recognizeWithRealModel`.
  - `recognizeWithRealModel`:
    - Uses `model_manager.ensureModelDir` to ensure a valid model directory.
    - Fails with explicit errors if models are missing or decoding fails.

### Model management (`model_manager.zig`)

- Handles where ASR models live and how they are downloaded:
  - Honors an environment override (`SHERPA_MODEL_DIR`).
  - Otherwise uses a fixed folder name (e.g. `sherpa-model/`) under a base directory.
  - Only requires `tokens.txt` to exist to consider the model “ready”.
  - Has a pluggable `DownloadFn` for tests (no real network needed in tests).

### Pipeline (`pipeline.zig`)

The core function:

```zig
pub fn transcribe_video_to_srt(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    cfg: PipelineConfig,
) Error![]u8
```

Steps:

1. Use `ffmpeg_adapter.build_ffmpeg_cmd` to spawn `ffmpeg` and read raw PCM from stdout (`decodePcmFromFfmpeg`).
2. Run `audio_segmenter.detect_speech_segments` on the PCM to find speech segments on the original timeline.
3. For each segment:
   - Slice the corresponding PCM window,
   - Convert to bytes (`s16le`),
   - Call `asr_sherpa.recognize` to get `[]SegmentResult` for that segment.
4. Optionally apply a small fixed time padding to the segment boundaries for better UX (`padSegmentsForSrt`).
5. Call `buildSrtFromSegments`, which:
   - For each segment + ASR result, computes:
     - `global_start_ms = segment.start_ms + local_start_ms`
     - `global_end_ms   = segment.start_ms + local_end_ms`
   - Builds an ordered list of `SubtitleItem` and emits a valid SRT string.

Result: subtitles are aligned to the original file’s timeline, even though only speech segments were sent to the recognizer.

### CLI (`main.zig` + `cli_options.zig`)

- `main.zig`:
  - Uses a `GeneralPurposeAllocator` to back the whole process.
  - Parses CLI args via `flaten.cli_options.parse`.
  - Constructs a `PipelineConfig` from parsed options.
  - Calls `flaten.pipeline.transcribe_video_to_srt`.
  - Writes the returned SRT to the requested output path.
  - Errors are printed with a short message and propagated via Zig’s error system.

---

## Limitations and Future Work

- Currently assumes:
  - Single-language (zh/en) use case based on the bundled zipformer model.
  - 16 kHz mono PCM for the internal pipeline.
- VAD is intentionally simple:
  - Energy-based with fixed thresholds.
  - No noise adaptation or sophisticated speech/phoneme modeling yet.
- Subtitles are one block per ASR segment:
  - No fine-grained word-level timing,
  - No extra splitting by punctuation or max characters per line.

Ideas for future iterations:

- Add simple noise floor estimation to auto-tune the VAD threshold.
- Smarter segmentation and subtitle splitting based on punctuation and target reading speed.
- More configuration flags in the CLI (e.g. VAD thresholds, padding values).
- Cross-platform build presets for Linux/macOS and possibly static bundling of sherpa-onnx.

---

## Special thanks

- **sherpa-onnx** – offline ASR engine and C API provided by the k2-fsa team: https://github.com/k2-fsa/sherpa-onnx/
- **FFmpeg** – battle-tested media toolkit used to decode input audio/video: https://ffmpeg.org/

`flaten` is an independent project and is not affiliated with the sherpa-onnx or FFmpeg maintainers.

---

## License

This project is licensed under the **Apache License 2.0**.
See the `LICENSE` file (or add one if missing) for full terms.

When you redistribute binaries built from this repository, please also respect the licenses of the third‑party components that may be bundled with them:

- **sherpa-onnx** – released by the k2-fsa project under the Apache License 2.0. If you ship `flaten` together with sherpa-onnx libraries or headers, you should include the sherpa-onnx license and any upstream notice files in your distribution and retain their copyright and attribution.
- **FFmpeg** – developed by the FFmpeg project and licensed under the LGPL or GPL, depending on how it is built. The default `flaten` packages invoke an `ffmpeg` executable that is provided by the host system and do **not** include FFmpeg binaries. If you create a custom bundle that ships FFmpeg alongside `flaten`, you are responsible for complying with FFmpeg’s license for that build (for example by providing the corresponding FFmpeg source code and license text).

Other dependencies such as onnxruntime follow their own upstream licenses. Before redistributing a custom package that includes any additional third‑party libraries, review those licenses and include the required notices with your distribution.

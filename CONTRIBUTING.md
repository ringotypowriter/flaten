# Contributing to flaten

Thanks for your interest in improving `flaten`!  
This document collects the “how it works” and “how to hack on it” details that would be too heavy for the main README.

---

## Development prerequisites

- Zig 0.15.x (developed and tested with 0.15.2)
- `ffmpeg` installed and on `PATH`
- sherpa-onnx C headers and shared libraries placed under:
  - `third_party/sherpa-onnx/v1.12.17/macos-universal/{include,lib}`
  - `third_party/sherpa-onnx/v1.12.17/linux-x86_64/{include,lib}` (for Linux builds)
- A sherpa-onnx offline model directory

By default the model manager will download a small zh-en zipformer model into `sherpa-model/`.  
You can override this with the `SHERPA_MODEL_DIR` environment variable.

---

## Build and test

- Build debug binary: `zig build`
- Run from source: `zig build run -- --input input.mp4 --output out.srt`
- Run tests: `zig build test`

Tests are designed to be fast and deterministic:

- ASR calls are stubbed in test builds (`"hello (stub)"`), so no real model or network is needed.
- `pipeline.zig` includes a small end-to-end test that uses [`test_resources/test.mp4`](./test_resources/test.mp4) and only asserts basic SRT structure.

---

## Project layout

- [`src/pipeline.zig`](./src/pipeline.zig) – orchestrates the end-to-end `transcribe_video_to_srt` pipeline.
- [`src/audio_segmenter.zig`](./src/audio_segmenter.zig) – energy-based VAD and speech segment detection.
- [`src/asr_sherpa.zig`](./src/asr_sherpa.zig) – sherpa-onnx C API wrapper.
- [`src/model_manager.zig`](./src/model_manager.zig) – model directory discovery and download logic.
- [`src/subtitle_writer.zig`](./src/subtitle_writer.zig) – SRT formatting and utilities.
- [`src/ffmpeg_adapter.zig`](./src/ffmpeg_adapter.zig) – builds the `ffmpeg` command line and decodes PCM.
- [`src/cli_options.zig`](./src/cli_options.zig) – CLI parsing and defaults.
- [`src/main.zig`](./src/main.zig) – CLI entrypoint.
- [`scripts/package_release.sh`](./scripts/package_release.sh) – create `dist/flaten-deploy-*` bundles.

---

## Architecture details

### VAD ([`audio_segmenter.zig`](./src/audio_segmenter.zig))

- Operates on raw PCM16 (`[]const i16`) at a given sample rate.
- Splits audio into fixed-size frames (20 ms by default), computes a simple energy per frame, and thresholds it.
- Configuration:
  - `min_speech_ms`: minimum total voiced duration for a valid segment.
  - `min_silence_ms`: silence shorter than this **does not** end an ongoing segment.

It returns an array of:

```zig
pub const SpeechSegment = struct {
    start_ms: u64, // original timeline
    end_ms: u64,
};
```

Timestamps are always in the original media timeline (silences included).

### ASR ([`asr_sherpa.zig`](./src/asr_sherpa.zig))

- Prepares audio (WAV parsing, mono conversion, resampling).
- Configures an offline recognizer and returns `[]SegmentResult { start_ms, end_ms, text }`.

Entry points:

- `recognize`:
  - In tests: returns a stub `"hello (stub)"`.
  - In normal builds: calls `recognizeWithRealModel`.
- `recognizeWithRealModel`:
  - Ensures a valid model directory via `model_manager.ensureModelDir`.
  - Fails explicitly when models are missing or decoding fails.

### Model management (`model_manager.zig`)

- Determines where models live and whether they are ready.
- Honors `SHERPA_MODEL_DIR` if set; otherwise uses a fixed folder such as `sherpa-model/` under a base dir.
- Considers the model “ready” when it can find `tokens.txt`.
- Uses an injectable `DownloadFn` in tests so no real network is needed.

### Pipeline ([`pipeline.zig`](./src/pipeline.zig))

The main function:

```zig
pub fn transcribe_video_to_srt(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    cfg: PipelineConfig,
) Error![]u8
```

Steps:

1. Build and spawn the `ffmpeg` command via `ffmpeg_adapter.build_ffmpeg_cmd`, reading raw PCM from stdout.
2. Run `audio_segmenter.detect_speech_segments` to obtain speech segments in the original timeline.
3. For each segment:
   - Slice the PCM window,
   - Convert to `s16le` bytes,
   - Call `asr_sherpa.recognize` to obtain segment-local results.
4. Optionally pad segment boundaries for nicer subtitle timing.
5. Use `buildSrtFromSegments` to convert back to global timeline timestamps and build the final SRT string.

### CLI ([`main.zig`](./src/main.zig) + [`cli_options.zig`](./src/cli_options.zig))

- `main.zig`:
  - Sets up a `GeneralPurposeAllocator`,
  - Parses arguments with `cli_options.parse`,
  - Constructs `PipelineConfig`,
  - Calls `pipeline.transcribe_video_to_srt` and writes the SRT file.
- `cli_options.zig`:
  - Provides flags for input, output, sample rate, and VAD parameters.
  - Performs basic validation and applies defaults.

---

## Packaging and cross-compilation

To build a local deployable bundle:

```bash
./scripts/package_release.sh
# output: dist/flaten-deploy-<platform>/
```

The bundle contains:

- `flaten` – wrapper that checks `ffmpeg` then invokes `bin/flaten-core`
- `bin/flaten-core` – the real CLI
- `lib/sherpa-onnx/` – sherpa-onnx and onnxruntime shared libraries
- `THIRD_PARTY_LICENSE_sherpa-onnx` – bundled license information

Cross-compiling (example: macOS → Linux x86_64):

```bash
export PKG_CONFIG_PATH=/path/to/linux-ffmpeg/lib/pkgconfig
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast -p dist/linux-x86_64
```

Then package the resulting binaries with `package_release.sh` or a similar layout.

---

## Code style

- Use `zig fmt` on all Zig sources before sending a PR.
- File names are snake_case; exported types use `CamelCase`; functions use `lowerCamel`.
- Keep I/O and FFI in dedicated modules; prefer small, pure helpers for core logic.
- Avoid hard-coded paths; prefer env vars (e.g. `SHERPA_MODEL_DIR`) or CLI options.
- Keep tests fast and deterministic; do not introduce network or large model downloads into tests.

---

## Sending changes

1. Fork and create a feature branch.
2. Make your changes, keeping commits focused.
3. Run `zig build test`.
4. Open a PR with:
   - A short summary of the change,
   - Notes on behavior and testing,
   - Any platform-specific considerations (e.g. Linux vs macOS).

Thanks again for helping improve `flaten`!

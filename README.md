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

- **Zig**: 0.15.x (project is developed and tested with 0.15.2)
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

---

## Building and Running

From the project root:

```bash
zig build run -- --input path/to/input.mp4 --output output.srt
```

Supported CLI flags (parsed in `src/cli_options.zig`):

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

The compiled binary is named `flaten` and is installed into Zig’s usual `zig-out/bin` directory by `zig build install`.

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

## License

This repository itself does not ship a license file yet; treat it as private/internal code unless explicitly licensed otherwise. Third‑party components (sherpa-onnx, ffmpeg, onnxruntime, etc.) are subject to their own licenses and terms. 请务必遵守它们各自的授权要求。


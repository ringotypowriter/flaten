# flaten

`flaten` is a small CLI tool written in Zig that turns a video or audio file into a speech-only `.srt` subtitle track.
Non-speech regions are skipped during recognition, but subtitle timestamps stay aligned to the original media timeline.

---

## Features

- Speech-only subtitle generation using `ffmpeg` + sherpa-onnx.
- Simple VAD tuned for conversational speech, configurable via CLI flags.
- Timeline-preserving SRT output (silence is kept in the timestamps).
- Cross-platform builds via Zig; packaged bundles include sherpa-onnx libs.

---

## Quick Start

Using a prebuilt bundle (recommended):

```bash
# after unpacking flaten-deploy-.../
export SHERPA_MODEL_DIR=/path/to/model   # or rely on the default auto-downloaded model
./flaten --input input.mp4 --output subtitles.srt
```

The output file defaults to `input.srt` when `--output` is omitted.

To see all CLI options (e.g. VAD parameters, sample rate), run:

```bash
./flaten --help
```

---

## Installation

### Prebuilt bundles

- Prebuilt `flaten-deploy-*` bundles are published on the project’s [Releases page](../../releases).
- Each bundle includes the `flaten` CLI and the sherpa-onnx libraries required to run it.
- On the target machine you only need `ffmpeg` installed and available on `PATH`.

### Models

`flaten` uses sherpa-onnx offline models:

- By default, the model manager will download a small zh-en zipformer model into `sherpa-model/` on first use.
- If you already have models, point `flaten` to them via the `SHERPA_MODEL_DIR` environment variable.

On macOS with Homebrew:

```bash
brew install ffmpeg
```

On Linux, install `ffmpeg` through your distribution’s package manager (for example, `sudo apt install ffmpeg` on Debian/Ubuntu).

---

## Development and Contributing

`flaten` is implemented in Zig 0.15.x.  
Bug reports, feature requests, and pull requests are welcome.

For building from source, running tests, and a detailed architecture overview, please see [CONTRIBUTING.md](./CONTRIBUTING.md) before opening a PR.

---

## Special thanks

- **sherpa-onnx** – offline ASR engine and C API provided by the k2-fsa team.
- **FFmpeg** – media toolkit used to decode input audio/video.

`flaten` is an independent project and is not affiliated with the sherpa-onnx or FFmpeg maintainers.

---

## License

This project is licensed under the **Apache License 2.0**.
See the [LICENSE](./LICENSE) file for full terms.

When you redistribute binaries built from this repository, please also respect the licenses of the third-party components that may be bundled with them:

- **sherpa-onnx** – released by the k2-fsa project under the Apache License 2.0. If you ship `flaten` together with sherpa-onnx libraries or headers, include the sherpa-onnx license and any upstream notice files in your distribution and retain their copyright and attribution.
- **FFmpeg** – developed by the FFmpeg project and licensed under the LGPL or GPL, depending on how it is built. The default `flaten` packages invoke an `ffmpeg` executable provided by the host system and do **not** include FFmpeg binaries. If you create a bundle that ships FFmpeg alongside `flaten`, you are responsible for complying with FFmpeg’s license for that build (for example, by providing the corresponding FFmpeg source code and license text).

Other dependencies such as onnxruntime follow their own upstream licenses. Before redistributing a custom package that includes any additional third‑party libraries, review those licenses and include the required notices with your distribution.

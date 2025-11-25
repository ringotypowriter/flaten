# Repository Guidelines

## Project Structure & Modules
- `src/`: Zig sources; key modules include `pipeline.zig` (orchestration), `asr_sherpa.zig`, `audio_segmenter.zig`, `subtitle_writer.zig`, `cli_options.zig`, and `ffmpeg_adapter.zig`.
- `scripts/`: helper tooling such as `package_release.sh` for building deployable bundles.
- `test_resources/`: small media fixtures used by integration tests; keep additions tiny to avoid repo bloat.
- `dist/` and `zig-out/`: build artifacts; regenerate locally, do not hand-edit. Package outputs land under `dist/flaten-deploy-*`.
- `third_party/`: vendored sherpa-onnx binaries/headers by platform; keep versions in sync with `build.zig`.

## Build, Test, and Dev Commands
- `zig build`: default Debug build; produces binaries in `zig-out/`.
- `zig build run -- --input input.mp4 --output out.srt`: run the CLI with arguments.
- `zig build test`: run all unit and pipeline tests; sherpa ASR is stubbed in test builds.
- `./scripts/package_release.sh [--target x86_64-linux-gnu]`: create `dist/flaten-deploy-*` bundles with wrapper + libs; needs ffmpeg present on the host or target-specific pkg-config when cross-compiling.

## Coding Style & Naming
- Use `zig fmt` before committing; default Zig formatting (4-space indent, trailing commas allowed).
- File names are snake_case; exported types use `CamelCase`, functions use `lowerCamel`, constants in `TitleCase`.
- Prefer small, pure helpers; keep FFI and IO boundaries isolated in dedicated modules (`ffmpeg_adapter`, `asr_sherpa`, `model_manager`).
- Avoid hard-coding paths; pass through env (e.g., `SHERPA_MODEL_DIR`) or CLI options.

## Testing Guidelines
- Keep tests fast and deterministic; ASR is already stubbed—do not add network/model dependencies to tests.
- Place tests near the code (`test` blocks inside Zig files); name with clear behavior strings (e.g., `test "ignores short blip"`).
- Run `zig build test` before pushes/PRs; add new fixtures under `test_resources/` only when essential and minimal.

## Commit & Pull Request Expectations
- Follow conventional commits seen in history: `feat:`, `chore:`, `fix:`, `refactor:`, etc., lowercase type + colon + short imperative summary.
- PRs should include: scope/intent summary, notable decisions, validation steps (`zig build test`, packaging if relevant), and any platform notes (macOS vs. Linux).
- Link related issues and attach logs for failing cases or cross-compile notes; add screenshots only when UI/CLI output is the focus.

## Security & Configuration Tips
- Do not commit large model files; rely on `model_manager` to download or point to models via `SHERPA_MODEL_DIR`.
- Keep sherpa-onnx versions aligned with `third_party/` layout expected by `build.zig`; update both headers and libs together.
- Ensure `ffmpeg` is on `PATH` when running or packaging; document the version used in PRs that touch media handling.

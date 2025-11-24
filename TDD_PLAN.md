# flaten TDD 迭代计划（当前日期：2025-11-24，地点：US）

> 目标：输入含人声的视频/音频，输出只含人声片段的 `output.srt`。采用“循序解锁”的 TDD，先写红灯测试，再逐步变绿。

## 模块与当前状态
- `subtitle_writer.zig` ✅ 已实现，测试绿。
- `cli_options.zig` ✅ 已实现，测试绿。
- `audio_segmenter.zig` 🚨 占位；已有红灯测试。
- `ffmpeg_adapter.zig` 🚨 占位；已有红灯测试。
- `asr_sherpa.zig` 🚨 占位；已有红灯测试。
- `pipeline.zig` 🚨 占位；已有红灯测试。

## 红灯测试概览（需逐步变绿）
- VAD：静音-有声-静音三段应检测一段约 1–2s；50ms 短 blip 在 `min_speech_ms=200` 下被忽略。
- ffmpeg 参数拼装：命令应包含 `ffmpeg -i <in> -ar <rate> -ac 1 -f s16le` 关键片段。
- ASR：对示例音频应返回含 "hello"/"world" 的文本（模糊断言）。
- Pipeline：在注入假 ffmpeg/VAD/ASR 数据时，应生成含 "HELLO" 与正确时间戳的 SRT。

## 推荐迭代顺序（逐步点绿）
1) 实现 `audio_segmenter.detect_speech_segments`（能量阈值 + 时间阈值）：满足两条 VAD 测试。
2) 实现 `ffmpeg_adapter.build_ffmpeg_cmd`：参数正确拼装；可新增契约测试（真实 ffmpeg 输出长度约等于 duration*sample_rate*2 字节）。
3) `asr_sherpa.recognize`：先用 mock/关键字匹配让测试模糊通过，再接 sherpa-onnx C API 写集成测试。
4) `pipeline.transcribe_video_to_srt`：先接入 mock ffmpeg/VAD/ASR 让测试绿，再逐步换成真实实现。
5) CLI 集成：在 `main.zig` 里接 `cli_options` + `pipeline`，补充参数错误路径测试。

## 未来扩展（后续迭代）
- VAD 改进：加入静音 padding、短暂停顿合并、多段并发 ASR。
- 平台支持：ffmpeg/sherpa 目标锁定 Linux x86_64 与 macOS arm64，必要时添加跨编译脚本。
- 性能与日志：增加并行度、日志级别 flag、可选保留中间文件。

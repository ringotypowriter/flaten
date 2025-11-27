const std = @import("std");
const builtin = @import("builtin");

/// High-level phases for the single-file transcription pipeline.
pub const PipelinePhase = enum {
    ffmpeg_decode,
    vad,
    asr,
    srt,
};

/// Lightweight progress tracker for the transcription pipeline.
/// Internally wraps std.Progress' global progress API but can be disabled
/// (no-op) for tests or non-interactive environments.
pub const PipelineProgress = struct {
    root: std.Progress.Node = .none,
    ffmpeg_node: std.Progress.Node = .none,
    vad_node: std.Progress.Node = .none,
    asr_node: std.Progress.Node = .none,
    srt_node: std.Progress.Node = .none,

    enabled: bool,

    // Local mirrors for unit tests and introspection. They do not affect
    // pipeline behavior but let tests assert expected bookkeeping without
    // relying on std.Progress internals.
    ffmpeg_total_samples: usize = 0,
    ffmpeg_completed_samples: usize = 0,
    vad_total_segments: usize = 0,
    vad_completed_segments: usize = 0,
    asr_total_segments: usize = 0,
    asr_completed_segments: usize = 0,
    srt_total_items: usize = 0,
    srt_completed_items: usize = 0,

    /// Initialize a PipelineProgress instance.
    /// If `enabled` is false, all update APIs become no-ops.
    /// When running in `zig test`, std.Progress is already used by the
    /// test runner, so we always downgrade to a no-op tracker there to
    /// avoid double-initializing the global progress state.
    pub fn init(enabled: bool) PipelineProgress {
        const active = enabled and !builtin.is_test;

        var self = PipelineProgress{
            .root = .none,
            .ffmpeg_node = .none,
            .vad_node = .none,
            .asr_node = .none,
            .srt_node = .none,
            .enabled = active,
        };

        if (active) {
            // Root node for the whole pipeline.
            self.root = std.Progress.start(.{
                .root_name = "Transcribing video",
                .estimated_total_items = 4,
            });

            // Child nodes for each major stage.
            self.ffmpeg_node = self.root.start("Decoding audio (ffmpeg)", 0);
            self.vad_node = self.root.start("Detecting speech segments", 0);
            self.asr_node = self.root.start("Running ASR", 0);
            self.srt_node = self.root.start("Building SRT", 0);
        }

        return self;
    }

    /// A convenience initializer for tests or non-interactive runs
    /// where we still want bookkeeping but not TTY progress output.
    pub fn initNoOp() PipelineProgress {
        return init(false);
    }

    pub fn deinit(self: *PipelineProgress) void {
        if (!self.enabled) return;
        // Child nodes are ended by the pipeline via the on*Done
        // helpers. Here we only end the root node once so that
        // std.Progress can shut down its update thread cleanly.
        self.root.end();
    }

    pub fn setFfmpegTotalSamples(self: *PipelineProgress, total_samples: usize) void {
        if (!self.enabled) {
            self.ffmpeg_total_samples = total_samples;
            return;
        }
        self.ffmpeg_total_samples = total_samples;
        self.ffmpeg_node.setEstimatedTotalItems(total_samples);
    }

    pub fn addFfmpegDecodedSamples(self: *PipelineProgress, delta_samples: usize) void {
        if (delta_samples == 0) return;
        self.ffmpeg_completed_samples += delta_samples;
        if (!self.enabled) return;
        const completed = if (self.ffmpeg_total_samples == 0)
            self.ffmpeg_completed_samples
        else
            @min(self.ffmpeg_completed_samples, self.ffmpeg_total_samples);
        self.ffmpeg_node.setCompletedItems(completed);
    }

    /// Mark the ffmpeg decoding stage as finished.
    pub fn onFfmpegDone(self: *PipelineProgress) void {
        if (!self.enabled) return;
        self.ffmpeg_node.end();
        self.root.completeOne();
    }

    pub fn setVadTotalSegments(self: *PipelineProgress, total: usize) void {
        if (!self.enabled) {
            self.vad_total_segments = total;
            return;
        }
        self.vad_total_segments = total;
        self.vad_node.setEstimatedTotalItems(total);
    }

    pub fn onVadSegmentDone(self: *PipelineProgress) void {
        self.vad_completed_segments += 1;
        if (!self.enabled) return;
        const completed = if (self.vad_total_segments == 0)
            self.vad_completed_segments
        else
            @min(self.vad_completed_segments, self.vad_total_segments);
        self.vad_node.setCompletedItems(completed);
    }

    pub fn onVadDone(self: *PipelineProgress) void {
        if (!self.enabled) return;
        self.vad_node.end();
        self.root.completeOne();
    }

    pub fn setAsrTotalSegments(self: *PipelineProgress, total: usize) void {
        if (!self.enabled) {
            self.asr_total_segments = total;
            return;
        }
        self.asr_total_segments = total;
        self.asr_node.setEstimatedTotalItems(total);
    }

    pub fn onAsrSegmentDone(self: *PipelineProgress) void {
        self.asr_completed_segments += 1;
        if (!self.enabled) return;
        const completed = if (self.asr_total_segments == 0)
            self.asr_completed_segments
        else
            @min(self.asr_completed_segments, self.asr_total_segments);
        self.asr_node.setCompletedItems(completed);
    }

    pub fn onAsrDone(self: *PipelineProgress) void {
        if (!self.enabled) return;
        self.asr_node.end();
        self.root.completeOne();
    }

    pub fn setSrtTotalItems(self: *PipelineProgress, total: usize) void {
        if (!self.enabled) {
            self.srt_total_items = total;
            return;
        }
        self.srt_total_items = total;
        self.srt_node.setEstimatedTotalItems(total);
    }

    pub fn onSrtItemDone(self: *PipelineProgress) void {
        self.srt_completed_items += 1;
        if (!self.enabled) return;
        const completed = if (self.srt_total_items == 0)
            self.srt_completed_items
        else
            @min(self.srt_completed_items, self.srt_total_items);
        self.srt_node.setCompletedItems(completed);
    }

    pub fn onSrtDone(self: *PipelineProgress) void {
        if (!self.enabled) return;
        self.srt_node.end();
        self.root.completeOne();
    }
};

test "no-op progress only updates local counters" {
    var p = PipelineProgress.initNoOp();

    p.setFfmpegTotalSamples(100);
    try std.testing.expectEqual(@as(usize, 100), p.ffmpeg_total_samples);

    p.addFfmpegDecodedSamples(40);
    p.addFfmpegDecodedSamples(10);
    try std.testing.expectEqual(@as(usize, 50), p.ffmpeg_completed_samples);

    p.setVadTotalSegments(3);
    p.onVadSegmentDone();
    p.onVadSegmentDone();
    try std.testing.expectEqual(@as(usize, 3), p.vad_total_segments);
    try std.testing.expectEqual(@as(usize, 2), p.vad_completed_segments);
}

test "enabled progress updates counters consistently" {
    var p = PipelineProgress.init(true);
    defer p.deinit();

    p.setFfmpegTotalSamples(1000);
    try std.testing.expectEqual(@as(usize, 1000), p.ffmpeg_total_samples);

    p.addFfmpegDecodedSamples(250);
    p.addFfmpegDecodedSamples(250);
    try std.testing.expectEqual(@as(usize, 500), p.ffmpeg_completed_samples);

    p.setAsrTotalSegments(4);
    p.onAsrSegmentDone();
    p.onAsrSegmentDone();
    try std.testing.expectEqual(@as(usize, 4), p.asr_total_segments);
    try std.testing.expectEqual(@as(usize, 2), p.asr_completed_segments);
}

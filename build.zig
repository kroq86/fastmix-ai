const std = @import("std");

const local_raylib_include = "third_party/raylib-44100/include";
const local_raylib_lib = "third_party/raylib-44100/lib";

fn hasLocalRaylib44100(b: *std.Build) bool {
    // Prefer Homebrew raylib for stable macOS output. Local 44100 build is opt-in:
    // set FASTMIX_USE_LOCAL_RAYLIB=1 after ./scripts/build_raylib_44100.sh
    _ = b;
    return false;
}

fn linkRaylib(b: *std.Build, module: *std.Build.Module) void {
    if (hasLocalRaylib44100(b)) {
        // Device locked to 44100 — see scripts/build_raylib_44100.sh
        module.addIncludePath(.{ .cwd_relative = local_raylib_include });
        module.addLibraryPath(.{ .cwd_relative = local_raylib_lib });
        // Absolute-enough rpath so zig-out/bin finds libraylib without DYLD_LIBRARY_PATH.
        module.addRPath(.{ .cwd_relative = local_raylib_lib });
    } else {
        module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }
    module.linkSystemLibrary("raylib", .{});
}

fn addRaylibExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkRaylib(b, module);

    return b.addExecutable(.{ .name = name, .root_module = module });
}

fn addRaylibSdlExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkRaylib(b, module);
    module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    module.linkSystemLibrary("SDL2", .{});

    return b.addExecutable(.{ .name = name, .root_module = module });
}

fn addPlainExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = target,
        .optimize = optimize,
    });
    return b.addExecutable(.{ .name = name, .root_module = module });
}

fn addRunStep(b: *std.Build, exe: *std.Build.Step.Compile, step_name: []const u8, step_desc: []const u8) void {
    // Install for `zig build` default, but do NOT make run steps wait on the
    // global install (which compiles every artifact, including unrelated ones
    // that may be mid-edit). addRunArtifact already builds this exe.
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step(step_name, step_desc);
    run_step.dependOn(&run_cmd.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = addRaylibExe(b, target, optimize, "fastmix-ai", "src/main.zig");
    addRunStep(b, exe, "run", "Run FastMix AI");

    const spike_stereo = addRaylibExe(b, target, optimize, "spike-stereo", "spikes/spike_stereo.zig");
    addRunStep(b, spike_stereo, "spike-stereo", "Run stereo AudioStream/pan spike");

    const spike_wav = addRaylibExe(b, target, optimize, "spike-wav", "spikes/spike_wav.zig");
    addRunStep(b, spike_wav, "spike-wav", "Run offline-render ExportWave spike");

    const spike_json = addPlainExe(b, target, optimize, "spike-json", "spikes/spike_json.zig");
    addRunStep(b, spike_json, "spike-json", "Run Project std.json roundtrip spike");

    const spike_midi = addPlainExe(b, target, optimize, "spike-midi", "spikes/spike_midi_parse.zig");
    addRunStep(b, spike_midi, "spike-midi", "Run MIDI byte-stream parser spike");

    const spike_ffmpeg = addRaylibExe(b, target, optimize, "spike-ffmpeg", "spikes/spike_ffmpeg_effects.zig");
    addRunStep(b, spike_ffmpeg, "spike-ffmpeg", "Run ffmpeg sidechaincompress spike");

    const spike_socket = addPlainExe(b, target, optimize, "spike-socket", "spikes/spike_socket.zig");
    addRunStep(b, spike_socket, "spike-socket", "Run control-socket (libc FFI) spike");

    const spike_stems = addRaylibExe(b, target, optimize, "spike-stems", "spikes/spike_stems.zig");
    addRunStep(b, spike_stems, "spike-stems", "Run audio-stem-import (LoadWave->f32) spike");

    const spike_sdl_capture = addRaylibSdlExe(b, target, optimize, "spike-sdl-capture", "spikes/spike_sdl_capture.zig");
    addRunStep(b, spike_sdl_capture, "spike-sdl-capture", "Run SDL2 capture + raylib output coexistence spike");

    const spike_atempo = addRaylibExe(b, target, optimize, "spike-atempo", "spikes/spike_atempo.zig");
    addRunStep(b, spike_atempo, "spike-atempo", "Run ffmpeg atempo bounded time-stretch spike");

    const spike_transients = addRaylibExe(b, target, optimize, "spike-transients", "spikes/spike_transients.zig");
    addRunStep(b, spike_transients, "spike-transients", "Run aubioonset transient detection spike");

    const spike_job_poll = addPlainExe(b, target, optimize, "spike-job-poll", "spikes/spike_job_poll.zig");
    addRunStep(b, spike_job_poll, "spike-job-poll", "Run non-blocking job spawn+poll spike");

    const spike_integration = addRaylibSdlExe(b, target, optimize, "spike-integration", "spikes/spike_integration.zig");
    addRunStep(b, spike_integration, "spike-integration", "Run combined socket+SDL+jobs+raylib integration spike");

    const spike_mixer = addPlainExe(b, target, optimize, "spike-mixer", "spikes/spike_mixer.zig");
    addRunStep(b, spike_mixer, "spike-mixer", "Run multi-track stereo mixer (mute/solo/pan) spike");

    const spike_undo = addPlainExe(b, target, optimize, "spike-undo", "spikes/spike_undo.zig");
    addRunStep(b, spike_undo, "spike-undo", "Run undo snapshot (deep-clone vs aliasing) spike");

    const spike_save_cache = addPlainExe(b, target, optimize, "spike-save-cache", "spikes/spike_save_cache.zig");
    addRunStep(b, spike_save_cache, "spike-save-cache", "Run atomic save + effect-cache staleness spike");

    const spike_core_model = addPlainExe(b, target, optimize, "spike-core-model", "spikes/spike_core_model.zig");
    addRunStep(b, spike_core_model, "spike-core-model", "Run core data model (union JSON + ID lookup) spike");

    // UI spikes (SPEC_UI_REAPER.md) — prove chrome/hit-test/items/waveform before integrating.
    const spike_ui_layout = addPlainExe(b, target, optimize, "spike-ui-layout", "spikes/spike_ui_layout.zig");
    addRunStep(b, spike_ui_layout, "spike-ui-layout", "Run UI chrome layout rect invariants spike");

    const spike_ui_hittest = addPlainExe(b, target, optimize, "spike-ui-hittest", "spikes/spike_ui_hittest.zig");
    addRunStep(b, spike_ui_hittest, "spike-ui-hittest", "Run UI hit-test priority spike");

    const spike_ui_tcp_mcp = addPlainExe(b, target, optimize, "spike-ui-tcp-mcp", "spikes/spike_ui_tcp_mcp.zig");
    addRunStep(b, spike_ui_tcp_mcp, "spike-ui-tcp-mcp", "Run UI TCP/MCP shared state + peak-hold spike");

    const spike_ui_items = addPlainExe(b, target, optimize, "spike-ui-items", "spikes/spike_ui_items.zig");
    addRunStep(b, spike_ui_items, "spike-ui-items", "Run UI item move/trim/fade/split under zoom spike");

    const spike_ui_waveform = addPlainExe(b, target, optimize, "spike-ui-waveform", "spikes/spike_ui_waveform.zig");
    addRunStep(b, spike_ui_waveform, "spike-ui-waveform", "Run UI offset-aware waveform + perf spike");

    const spike_ui_transport = addPlainExe(b, target, optimize, "spike-ui-transport", "spikes/spike_ui_transport.zig");
    addRunStep(b, spike_ui_transport, "spike-ui-transport", "Run UI transport Play/Stop vs Record state machine spike");

    const spike_ui_chrome = addRaylibExe(b, target, optimize, "spike-ui-chrome", "spikes/spike_ui_chrome.zig");
    addRunStep(b, spike_ui_chrome, "spike-ui-chrome", "Run UI chrome raylib draw+resize smoke spike");

    // P0 audio-feedback-loop regression suite (real per-track meters, GR/detector
    // telemetry, deterministic measure, audition, operation/revision envelope).
    // Imports src/main.zig directly to exercise the real production code, so it
    // needs raylib linked even though it never opens a window.
    const spike_p0_regression = addRaylibExe(b, target, optimize, "spike-p0-regression", "src/test_p0_regression.zig");
    addRunStep(b, spike_p0_regression, "spike-p0-regression", "Run P0 audio-feedback-loop regression suite");

    // Peaking EQ realtime DSP (positive hearability via measure).
    const spike_fx_dsp_gaps = addRaylibExe(b, target, optimize, "spike-fx-dsp-gaps", "src/test_fx_dsp_gaps.zig");
    addRunStep(b, spike_fx_dsp_gaps, "spike-fx-dsp-gaps", "Run peaking EQ realtime DSP suite");

    // Professional-trial scaffold (begin/resolve/confirm/reject + three decisions).
    const spike_trial = addRaylibExe(b, target, optimize, "spike-trial", "src/test_trial.zig");
    addRunStep(b, spike_trial, "spike-trial", "Run professional trial scaffold suite");

    // P1 compressor DSP + assess workflow.
    const spike_compressor_workflow = addRaylibExe(b, target, optimize, "spike-compressor-workflow", "src/test_compressor_workflow.zig");
    addRunStep(b, spike_compressor_workflow, "spike-compressor-workflow", "Run P1 compressor feedback-loop suite");

    // P1 bus/send routing + bus compressor + delay return.
    const spike_routing_workflow = addRaylibExe(b, target, optimize, "spike-routing-workflow", "src/test_routing_workflow.zig");
    addRunStep(b, spike_routing_workflow, "spike-routing-workflow", "Run P1 bus/send routing workflow suite");

    // P1 master FX + master compressor trial + realtime policy.
    const spike_master_workflow = addRaylibExe(b, target, optimize, "spike-master-workflow", "src/test_master_workflow.zig");
    addRunStep(b, spike_master_workflow, "spike-master-workflow", "Run P1 master FX feedback-loop suite");

    // P2 master limiter + loudness / true-peak delivery QC.
    const spike_mastering_qc = addRaylibExe(b, target, optimize, "spike-mastering-qc-workflow", "src/test_mastering_qc_workflow.zig");
    addRunStep(b, spike_mastering_qc, "spike-mastering-qc-workflow", "Run P2 limiter / loudness / delivery QC suite");

    // P2 vocal-balance feedback loop (preflight → section analyze → bounded trial).
    const spike_vocal_balance = addRaylibExe(b, target, optimize, "spike-vocal-balance-workflow", "src/test_vocal_balance_workflow.zig");
    addRunStep(b, spike_vocal_balance, "spike-vocal-balance-workflow", "Run P2 vocal-balance preflight/section/trial suite");

    // Unit 1: parametric EQ types (peak/shelf/HPF + Q).
    const spike_eq_filter_types = addRaylibExe(b, target, optimize, "spike-eq-filter-types", "src/test_eq_filter_types.zig");
    addRunStep(b, spike_eq_filter_types, "spike-eq-filter-types", "Run parametric EQ filter-types suite");

    const spike_stereo_width = addRaylibExe(b, target, optimize, "spike-stereo-width-workflow", "src/test_stereo_width_workflow.zig");
    addRunStep(b, spike_stereo_width, "spike-stereo-width-workflow", "Run stereo width / M-S feedback-loop suite");
}

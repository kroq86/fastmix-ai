const std = @import("std");

// Spike: roadmap §4 multi-track stereo mixer. The stereo spike (spike_stereo.zig)
// only proved the frameCount/UpdateAudioStream mechanics with a single tone;
// it never tested actual multi-track summing with volume/pan/mute/solo
// combined. This spike synthesizes 3 tracks at distinct frequencies, mixes
// them per the §4 rule, and verifies correctness with a Goertzel single-
// frequency magnitude detector (simple, no external tool needed) rather than
// just trusting the code compiled and didn't crash.

const SAMPLE_RATE: f32 = 44100.0;
const N: usize = 4096; // analysis window

const Track = struct {
    freq: f32,
    volume: f32 = 1.0,
    pan: f32 = 0.0, // -1..1
    mute: bool = false,
    solo: bool = false,
};

// Goertzel algorithm: magnitude of a single target frequency bin in `samples`,
// without a full FFT -- exactly enough to verify "is this frequency present
// and how loud", which is all we need to check mixing/mute/solo/pan.
fn goertzelMagnitude(samples: []const f32, target_freq: f32) f32 {
    const k = @round(@as(f32, @floatFromInt(samples.len)) * target_freq / SAMPLE_RATE);
    const w = 2.0 * std.math.pi * k / @as(f32, @floatFromInt(samples.len));
    const cw = @cos(w);
    const coeff = 2.0 * cw;

    var q0: f32 = 0;
    var q1: f32 = 0;
    var q2: f32 = 0;
    for (samples) |s| {
        q0 = coeff * q1 - q2 + s;
        q2 = q1;
        q1 = q0;
    }
    const real = q1 - q2 * cw;
    const imag = q2 * @sin(w);
    return @sqrt(real * real + imag * imag) / @as(f32, @floatFromInt(samples.len)) * 2.0;
}

fn panGains(pan: f32) struct { l: f32, r: f32 } {
    // equal-power pan law, same as the original synth's approach
    const angle = (pan + 1.0) * (std.math.pi / 4.0);
    return .{ .l = @cos(angle), .r = @sin(angle) };
}

// Mix `tracks` into an interleaved stereo buffer of `frame_count` frames,
// applying the exact §4 rule: mute skips, solo (if any track soloed) mutes
// all non-soloed tracks regardless of their own mute flag.
fn mixStereo(tracks: []const Track, frame_count: usize, out: []f32) void {
    const any_solo = for (tracks) |t| {
        if (t.solo) break true;
    } else false;

    for (0..frame_count) |i| {
        const t: f32 = @as(f32, @floatFromInt(i)) / SAMPLE_RATE;
        var l: f32 = 0;
        var r: f32 = 0;
        for (tracks) |tr| {
            if (tr.mute) continue;
            if (any_solo and !tr.solo) continue;
            const sample = @sin(2.0 * std.math.pi * t * tr.freq) * tr.volume;
            const gains = panGains(tr.pan);
            l += sample * gains.l;
            r += sample * gains.r;
        }
        out[i * 2 + 0] = std.math.clamp(l, -1.0, 1.0);
        out[i * 2 + 1] = std.math.clamp(r, -1.0, 1.0);
    }
}

fn deinterleave(gpa: std.mem.Allocator, stereo: []const f32, channel: usize) ![]f32 {
    const frame_count = stereo.len / 2;
    const out = try gpa.alloc(f32, frame_count);
    for (0..frame_count) |i| out[i] = stereo[i * 2 + channel];
    return out;
}

const PRESENT_THRESHOLD: f32 = 0.05;

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const buf = try gpa.alloc(f32, N * 2);
    defer gpa.free(buf);

    std.debug.print("=== test 1: all 3 tracks unmuted, no solo -- all present ===\n", .{});
    {
        const tracks = [_]Track{
            .{ .freq = 220, .pan = 0 },
            .{ .freq = 440, .pan = 0 },
            .{ .freq = 880, .pan = 0 },
        };
        mixStereo(&tracks, N, buf);
        const left = try deinterleave(gpa, buf, 0);
        defer gpa.free(left);
        const m220 = goertzelMagnitude(left, 220);
        const m440 = goertzelMagnitude(left, 440);
        const m880 = goertzelMagnitude(left, 880);
        std.debug.print("magnitudes: 220Hz={d:.3} 440Hz={d:.3} 880Hz={d:.3}\n", .{ m220, m440, m880 });
        if (m220 < PRESENT_THRESHOLD or m440 < PRESENT_THRESHOLD or m880 < PRESENT_THRESHOLD) {
            std.debug.print("FAIL: expected all 3 frequencies present\n", .{});
            return error.TrackMissing;
        }
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("\n=== test 2: mute 440Hz track -- 220/880 remain, 440 drops out ===\n", .{});
    {
        const tracks = [_]Track{
            .{ .freq = 220, .pan = 0 },
            .{ .freq = 440, .pan = 0, .mute = true },
            .{ .freq = 880, .pan = 0 },
        };
        mixStereo(&tracks, N, buf);
        const left = try deinterleave(gpa, buf, 0);
        defer gpa.free(left);
        const m220 = goertzelMagnitude(left, 220);
        const m440 = goertzelMagnitude(left, 440);
        const m880 = goertzelMagnitude(left, 880);
        std.debug.print("magnitudes: 220Hz={d:.3} 440Hz={d:.3} 880Hz={d:.3}\n", .{ m220, m440, m880 });
        if (m440 > PRESENT_THRESHOLD or m220 < PRESENT_THRESHOLD or m880 < PRESENT_THRESHOLD) {
            std.debug.print("FAIL: mute didn't behave as expected\n", .{});
            return error.MuteBroken;
        }
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("\n=== test 3: solo 880Hz track -- only 880 present, regardless of others' mute ===\n", .{});
    {
        const tracks = [_]Track{
            .{ .freq = 220, .pan = 0 },
            .{ .freq = 440, .pan = 0 },
            .{ .freq = 880, .pan = 0, .solo = true },
        };
        mixStereo(&tracks, N, buf);
        const left = try deinterleave(gpa, buf, 0);
        defer gpa.free(left);
        const m220 = goertzelMagnitude(left, 220);
        const m440 = goertzelMagnitude(left, 440);
        const m880 = goertzelMagnitude(left, 880);
        std.debug.print("magnitudes: 220Hz={d:.3} 440Hz={d:.3} 880Hz={d:.3}\n", .{ m220, m440, m880 });
        if (m220 > PRESENT_THRESHOLD or m440 > PRESENT_THRESHOLD or m880 < PRESENT_THRESHOLD) {
            std.debug.print("FAIL: solo didn't isolate the soloed track\n", .{});
            return error.SoloBroken;
        }
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("\n=== test 4: hard pan -- left track inaudible in R, right track inaudible in L ===\n", .{});
    {
        const tracks = [_]Track{
            .{ .freq = 220, .pan = -1.0 }, // hard left
            .{ .freq = 880, .pan = 1.0 }, // hard right
        };
        mixStereo(&tracks, N, buf);
        const left = try deinterleave(gpa, buf, 0);
        defer gpa.free(left);
        const right = try deinterleave(gpa, buf, 1);
        defer gpa.free(right);

        const l_220 = goertzelMagnitude(left, 220);
        const l_880 = goertzelMagnitude(left, 880);
        const r_220 = goertzelMagnitude(right, 220);
        const r_880 = goertzelMagnitude(right, 880);
        std.debug.print("L channel: 220Hz={d:.3} 880Hz={d:.3}\n", .{ l_220, l_880 });
        std.debug.print("R channel: 220Hz={d:.3} 880Hz={d:.3}\n", .{ r_220, r_880 });

        if (l_220 < PRESENT_THRESHOLD or r_880 < PRESENT_THRESHOLD) {
            std.debug.print("FAIL: expected 220Hz strong in L, 880Hz strong in R\n", .{});
            return error.PanBroken;
        }
        if (l_880 > PRESENT_THRESHOLD * 0.3 or r_220 > PRESENT_THRESHOLD * 0.3) {
            std.debug.print("FAIL: hard-panned tracks leaking into the opposite channel more than expected\n", .{});
            return error.PanLeaking;
        }
        std.debug.print("PASS\n", .{});
    }

    std.debug.print("\nPASS: multi-track stereo mixing (mute/solo/pan) all verified correct via Goertzel frequency analysis\n", .{});
}

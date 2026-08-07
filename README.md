# FastMix AI
<img width="1431" height="843" alt="Screenshot 2026-08-07 at 3 40 15 PM" src="https://github.com/user-attachments/assets/dc4415ef-b697-4927-8e4e-e432baa7568f" />

**An AI-first DAW: a real-time multi-track mixer, EQ/compressor/limiter/sidechain/delay/stereo-width DSP, and bus routing, driven directly by an AI agent through a deterministic measure → change → measure → commit/rollback feedback loop — not remote-controlled through a GUI automation layer bolted onto a human-first DAW.**

Built in [Zig](https://ziglang.org/) + [raylib](https://www.raylib.com/), with a Unix-socket JSON API and an [MCP](https://modelcontextprotocol.io/) bridge so an LLM agent (Claude, GPT, etc.) can mix and master a real project directly.

## Why

Today, getting an AI agent to mix or master inside a conventional DAW means scripting the GUI, rendering to a file, reopening it, and hoping the agent can infer what changed from a waveform screenshot — a slow, lossy, render-reopen round trip. There's no structured way for the agent to know **what a parameter change actually did to the sound**, compare the same slice of audio before and after, or safely roll back a change that didn't work.

FastMix AI inverts that: the primary interface *is* the API. Every mixing/mastering operation an agent can take follows the same shape —

```text
fix a frame range
  -> measure baseline (peak, RMS, gain reduction, spectral bands, loudness)
  -> change exactly one parameter
  -> measure the SAME range again
  -> check the result against explicit technical constraints
  -> commit, or roll back automatically
```

— with real before/after audio you can actually listen to (`audition`), not just a parameter readback.

## vs. Reaper + an MCP server

You *can* wire an MCP server up to Reaper's ReaScript API today, and it genuinely gives an agent remote control: set parameters, trigger actions, render. The honest comparison isn't "Reaper can't be automated" — it's what's built into the protocol vs. what you'd have to build yourself on top of it.

| | Reaper + ReaScript MCP | FastMix AI |
|---|---|---|
| Set a parameter | Yes | Yes |
| Know the parameter *took effect* | Yes (readback) | Yes (readback) |
| Know what it *did to the sound* | Not built in — you'd script a time-selection render, decode the WAV, and compute your own metrics | Native: `measure`/`audition` return peak/RMS/gain-reduction/spectral/loudness for an exact frame range |
| Compare the *same* audio slice before vs. after | Not built in — same manual render-and-diff work, and nothing stops the "after" render from silently drifting to a different range | Native: `start_frame`/`length_frames` is the unit every measurement is keyed on |
| See *why* a compressor/limiter is doing what it's doing | Not exposed — Reaper's own gain-reduction metering isn't part of the automatable API surface | Native: `gain_reduction_peak_db`/`detector_peak_db` per effect, per call |
| Tie a measured change back to the command that caused it | Not built in — you'd invent your own IDs | Native: every mutating call returns `operation_id` + `revision_before`/`revision` + `applied_at_audio_frame` |
| Try a change, auto-revert if it didn't hit target | Not built in — you'd script it | Native: the `*_assess_and_adjust` commands *are* this — measure, change, re-measure, commit or roll back, every time |
| Plugin ecosystem, format support, general DAW maturity | Enormous, battle-tested | None of that — six DSP types, no plugin hosting |
| GUI completeness for a human mix engineer | Full-featured | Reaper-inspired chrome, not a replacement |

So the real claim is narrower than "better than Reaper": Reaper + MCP gives an agent *remote control*. FastMix AI gives an agent *remote control plus a typed, deterministic feedback loop as part of the protocol itself*, at the cost of being nowhere near Reaper as a general-purpose DAW. If you need the plugin ecosystem, use Reaper. If you're building an agent that needs to *prove* a mix change worked before keeping it, this is closer to what that agent actually needs out of the box.

## What's actually in it

- **Real-time multi-track mixer**: mute/solo/pan/volume, per-track meters that are actually per-track (not a copy of the master signal).
- **Real DSP inserts**: parametric EQ (RBJ-cookbook biquads: peak/low-shelf/high-shelf/highpass), compressor, sidechain compressor, delay, sample-peak limiter, Mid/Side stereo width — on tracks, buses, *and* master.
- **Bus routing**: sends (pre/post-fader), per-bus FX chains, bus mute/solo.
- **Deterministic analysis**: `measure`/`audition` re-derive exactly what a fixed frame range sounds like — independent of live playback state, safe to call from an agent while the song is playing (heavy calls run on a background thread so they never glitch the realtime mix).
- **Bounded assess-and-adjust workflows**, one per effect type (sidechain, EQ, compressor, bus compressor, master compressor, master limiter, stereo width): measure baseline → change one parameter → re-measure → check against constraints → commit or roll back, every time, with before/after audition WAVs.
- **A causality envelope** on every mutating command (`operation_id`, `revision_before`/`revision`, `applied_at_audio_frame`) so an agent can always tie a measured change back to the exact command that caused it.
- **Mix session preflight**: a read-only integrity gate (checks relative timing, section structure) that must pass before higher-level mix assistance (like vocal-balance assessment) is allowed to touch the project.
- **Loudness/delivery QC**: from-scratch ITU-R BS.1770 / EBU R128-style loudness measurement, true-peak estimation, delivery validation.
- **MCP bridge** (`mcp/fastmix-ai/`): exposes the full command surface as MCP tools, so any MCP-capable agent can drive it directly.

## Status

This is an active, fast-moving personal project, not a finished product.

- Built and tested primarily against **AI-generated stems from [Suno](https://suno.com/)** — 8-track stem exports (vocals/backing vocals/drums/bass/guitar/keys/synth/other), including a stem-alignment feature (`ALIGN`) that snaps clips to the beat grid using onset detection, since Suno stems don't always start exactly on the downbeat. It should work with any multi-track audio, but that's the workflow it's actually been exercised against.
- The Unix socket (`/tmp/fastmix-ai.sock`) has **no authentication** — anything that can reach it locally can issue commands. Fine for solo local use; not designed for a shared/multi-user host.
- Single job slot: only one heavy background analysis (measure/audition/assess-and-adjust) runs at a time.
- The GUI is a Reaper-inspired chrome (transport, track/mixer panels, waveform view) for a human to watch/steer the same project the agent is driving — it is not trying to be a complete traditional DAW UI.

## Platform & raylib (what actually works)

**Verified on one machine only:**

| Piece | Tested version / note |
|---|---|
| Host | Apple Silicon Mac (arm64 / M1-class), macOS 26.2 |
| Zig | **0.16.0** (`minimum_zig_version` in `build.zig.zon`) |
| raylib | Homebrew **5.5** (`libraylib.5.5.0.dylib` via `/opt/homebrew`) |
| ffmpeg | Homebrew **8.x** (atempo / decode helpers in spikes) |
| aubio | Homebrew **0.4.9** (onset / ALIGN / tempo probes) |

**Not tested:** Intel Mac, Linux, Windows, raylib 6.x, Zig ≠ 0.16.

### How raylib is linked today

`build.zig` does **not** fetch or compile raylib through the Zig package manager. It **system-links** Homebrew’s install and hardcodes Apple Silicon Homebrew prefixes:

```text
/opt/homebrew/include
/opt/homebrew/lib
```

So on another machine:

1. **Apple Silicon Mac + Homebrew** — same path as here: `brew install zig raylib ffmpeg aubio`, then `zig build run`. Most likely path to success.
2. **Intel Mac** — Homebrew lives under `/usr/local`, not `/opt/homebrew`. The current `build.zig` will not find headers/libs until those paths are changed (or `pkg-config` wiring is added). Untested.
3. **Linux** — install distro `libraylib-dev` (or build raylib yourself), then point `build.zig` at your include/lib dirs. Untested; OpenGL / audio backend differences are expected.
4. **Windows** — unsupported; no build path checked in.

Optional local raylib built at 44.1 kHz (`scripts/build_raylib_44100.sh` → `third_party/raylib-44100/`) exists as an experiment. In current `build.zig`, `hasLocalRaylib44100` is **hard-disabled** (`return false`) — shipping builds use Homebrew raylib. Do **not** assume a custom sample-rate raylib is required or active.

Audio note: Project stems are often **44100 Hz** while CoreAudio devices frequently run at **48000 Hz**. Raylib/miniaudio handles device rate; fighting the OS sample rate has caused silence on some outputs in the past. Prefer letting the device stay at its native rate.

## Install (Apple Silicon macOS)

This is the only path that has actually been run end-to-end. Other OSes need `build.zig` path fixes first (see Platform above).

### 1. Homebrew

If you do not have it yet: https://brew.sh

### 2. Dependencies

```sh
brew install zig raylib ffmpeg aubio
```

Pin expectation to what this repo was built against:

```sh
zig version          # expect 0.16.x
brew list --versions raylib ffmpeg aubio
# raylib 5.5  (libraylib under /opt/homebrew/lib)
# ffmpeg 8.x
# aubio 0.4.9
```

Sanity-check that headers/libs land where `build.zig` looks:

```sh
ls /opt/homebrew/include/raylib.h
ls /opt/homebrew/lib/libraylib.dylib
```

If those paths are missing, you are not on Apple Silicon Homebrew (or brew is not linked) — the stock `build.zig` will not compile until paths are updated.

### 3. Clone & build

```sh
git clone <this-repo-url> fastmix-ai
cd fastmix-ai
zig build
# binary:
ls zig-out/bin/fastmix-ai
```

Faster rebuild while iterating:

```sh
zig build -Doptimize=ReleaseSafe
```

### 4. Run

```sh
# empty / last UI defaults
zig build run
# or:
./zig-out/bin/fastmix-ai

# bootstrap 8 stems from a folder (Suno-style export works):
FASTMIX_BOOTSTRAP="/path/to/stems" zig build run

# load a saved session:
./zig-out/bin/fastmix-ai --load path/to/project.fastmix.json

# env equivalent:
FASTMIX_LOAD=path/to/project.fastmix.json ./zig-out/bin/fastmix-ai
```

On success you get:

- GUI window (transport / tracks / mixer)
- Unix control socket: **`/tmp/fastmix-ai.sock`**

Check the socket:

```sh
ls -l /tmp/fastmix-ai.sock
```

### 5. MCP agent bridge (optional)

Needs **Node 18+** and the app already running.

```sh
cd mcp/fastmix-ai
npm install
node index.mjs   # stdio MCP server → /tmp/fastmix-ai.sock
```

Point your MCP client at that entry (Cursor example — put under MCP servers config):

```json
{
  "mcpServers": {
    "fastmix-ai": {
      "command": "node",
      "args": ["/absolute/path/to/fastmix-ai/mcp/fastmix-ai/index.mjs"]
    }
  }
}
```

From the agent: call `fastmix_ping` first. If the DAW is not running, ping fails — start `fastmix-ai`, then retry.

Override socket path if needed:

```sh
FASTMIX_SOCK=/tmp/fastmix-ai.sock node index.mjs
```

### 6. Tests

```sh
zig build spike-p0-regression
zig build spike-fx-dsp-gaps
zig build spike-compressor-workflow
zig build spike-stereo-width-workflow
# full list: see build.zig
```

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| `raylib.h` / link errors | Not Apple Silicon brew, or `raylib` not installed; check `/opt/homebrew/...` |
| Zig version errors | Need Zig **0.16**; older/newer may not match `build.zig.zon` |
| App runs, no sound | Output device / OS sample rate; try system speakers; do not force CoreAudio to 44100 |
| `fastmix_ping` fails | App not running, or socket not at `/tmp/fastmix-ai.sock` |
| Crackles under full FX | Raise buffer in UI Options (audio block size); this machine settled at **4096** frames |

## Quick commands

```sh
brew install zig raylib ffmpeg aubio
zig build run
FASTMIX_BOOTSTRAP="/path/to/stems" zig build run
./zig-out/bin/fastmix-ai --load project.fastmix.json
```

## License

[PolyForm Noncommercial 1.0.0](LICENSE) — free to use, study, modify, and contribute to for any noncommercial purpose. Commercial use is not permitted under this license.

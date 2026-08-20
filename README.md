# Audora macOS — local setup

This fork builds the macOS recorder in local-only mode:

- authentication uses the loopback JWT issuer at `127.0.0.1:5173`;
- data syncs only to the loopback Convex backend at `127.0.0.1:3210`;
- transcription is forced to FluidAudio's local Parakeet TDT v3 provider;
- Clerk, Speechmatics, PostHog, Sparkle, and the unused OpenAI Swift package are absent from the target.

The web coaching bridge is separate. It invokes the locally installed Codex CLI using your existing ChatGPT login. Transcript text sent to that bridge is processed by OpenAI and consumes your Codex subscription allowance; recordings are not sent by the bridge.

## Requirements

- Apple Silicon Mac
- macOS 15 or newer
- Full Xcode (Command Line Tools alone are insufficient)
- The parent Audora local web and Convex services running first

See `docs/LOCAL_CODEX_SETUP.md` in the parent repository for the complete backend and Codex setup.

## Build and run

The parent repository's `scripts/setup-local.mjs` command incrementally builds an optimized Release app with Xcode's ad-hoc **Sign to Run Locally** identity. It then launches a dedicated preparation mode which downloads and validates Parakeet TDT v3 and Silero VAD inside the signed app's actual sandbox container. A valid cache is reused on later setup runs.

For development, open `audora.xcodeproj`, let Xcode resolve the pinned packages, select **Sign to Run Locally**, and run the shared `Audora` scheme for **My Mac**. Its Run action uses the optimized Release configuration while retaining `AUDORA_LOCAL_SETUP`. Keep the default `com.audora.local` bundle identifier so updates continue to use the prepared container.

The app requests microphone and system-audio permissions. Starting a recording loads the already-cached Parakeet and VAD models into memory; it downloads only if setup was skipped or the model cache was removed or invalidated. Progress is shown beside the recording controls.

Parakeet word timings and confidence are preserved. A dependency-free Swift analyzer calculates per-source phrase and overall pace, articulation, pitch range/direction, relative volume, volume variation, steadiness, voiced coverage, and quality flags away from the realtime audio callback. It creates no voice embedding or pitch contour. Detailed metrics stay in the local meeting JSON; the loopback backend receives a rounded, capped projection, and absolute median pitch is removed before Codex coaching. Transcript and metric phrase rows seek directly to their saved-audio timestamps.

## Network expectations

- First source build: GitHub traffic for Swift packages.
- Model preparation during parent setup: traffic to FluidAudio's configured model hosts for Parakeet and Silero VAD.
- Warm recording and local Convex sync: loopback traffic only.
- Coaching in the web UI: transcript text is sent through the Codex CLI to OpenAI.

Local meeting JSON and speech-optimized WAV audio files are stored in the app sandbox without additional at-rest encryption. The final recording is a time-aligned mix of microphone and system audio at 16 kHz mono Int16 PCM (roughly 115 MB per recorded hour). Lossless per-source CAF files are retained until that WAV is installed atomically, so allow additional temporary disk space while long recordings are finalized. Treat this fork as a single-user development setup and stop the local services when testing is complete.

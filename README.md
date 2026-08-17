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

1. Open `audora.xcodeproj` in Xcode.
2. Let Xcode resolve the pinned Convex Swift and FluidAudio packages.
3. In **Signing & Capabilities**, select your Personal Team or choose **Sign to Run Locally**.
4. The fork defaults to `com.audora.local`. If that identifier is unavailable to your team, set `AUDORA_PRODUCT_BUNDLE_IDENTIFIER` in the ignored `Config.xcconfig`.
5. Select **My Mac** and run the `Audora` scheme. Its Run action uses the optimized Release configuration while retaining `AUDORA_LOCAL_SETUP`.

The app requests microphone and system-audio permissions. On the first recording it downloads and initializes the Parakeet v3 and Silero VAD assets from Hugging Face before audio capture begins; progress is shown beside the recording controls. Later recordings transcribe locally from the cached models.

## Network expectations

- First source build: GitHub traffic for Swift packages.
- First model setup: Hugging Face/CDN traffic for Parakeet and Silero VAD.
- Warm recording and local Convex sync: loopback traffic only.
- Coaching in the web UI: transcript text is sent through the Codex CLI to OpenAI.

Local meeting JSON and speech-optimized WAV audio files are stored in the app sandbox without additional at-rest encryption. The final recording is a time-aligned mix of microphone and system audio at 16 kHz mono Int16 PCM (roughly 115 MB per recorded hour). Lossless per-source CAF files are retained until that WAV is installed atomically, so allow additional temporary disk space while long recordings are finalized. Treat this fork as a single-user development setup and stop the local services when testing is complete.

# Yogurt

<p align="center">
  <img width="600" alt="yogurt-screenshot" src="https://github.com/user-attachments/assets/ae8b516b-72dd-4928-b3d7-f07b111c0e39">
</p>

Yogurt is a macOS notes app that enhances meeting notes by capturing and transcribing both system audio and microphone input. Audio processing and note enhancement is powered by [Cloudflare Workers AI](https://developers.cloudflare.com/workers-ai/).

* All AI transcription and enhancement takes place on a [Cloudflare Worker](https://developers.cloudflare.com/workers/) you own, running on **your Cloudflare account**.
* Your transcripts or audio recordings are **not stored remotely anywhere**.

This respository contains the source code for the macOS app. You'll need to deploy the [Yogurt Cloudflare Worker](https://github.com/jonesphillip/yogurt-worker) to handle transcription and enhancing notes.

Heavily inspired by [Granola](https://www.granola.ai/).

## Installation
You can either:
- [Download the latest release](https://github.com/jonesphillip/yogurt/releases/latest)
- Or build from source (see [Development](#development) below)

On first launch, you'll need to configure your Cloudflare Worker URL in the settings.

## Features
- Markdown support (including headings, lists, inline code blocks, and more)
- Audio capture
  - System-wide audio
  - Specific application audio (e.g., Zoom, browsers for Google Meet)
  - Microphone input
- Transcript-aware note enhancement that integrates raw transcripts, key points, action items, and personal notes into refined meeting notes
- Automatic versioning of notes to keep historical copies for easy reference or rollback
- Stores notes locally as Markdown (.md) files

## System requirements

Yogurt supports macOS v14.4 or later. You'll need Xcode 15.0 or later to develop.

## Development

1. Clone the repository:
   ```bash
   git clone https://github.com/jonesphillip/yogurt.git
   cd yogurt
   ```

2. Open the project in Xcode:
   ```bash
   xed .
   ```

3. Build and run the project (⌘R)

## Cloudflare Worker configuration

The app requires a [Cloudflare Worker](https://developers.cloudflare.com/workers/) with these endpoints:

- `/transcribe`: Receives raw audio (WAV/base64) and returns a transcript
- `/transcription-notes`: Takes the transcript and produces concise bullet-style notes.
- `/points-of-emphasis`: Compares your notes to the transcript notes to identify shared emphasis points.
- `/action-items`: Extracts all actionable tasks or follow-ups found in your notes + transcript notes.
- `/final-notes`: Combines your notes, transcript notes, points of emphasis, and action items into a final “enhanced” version of your meeting notes.

The Worker should accept:
- Audio data in WAV format for transcription
- JSON payloads with appropriate fields for each stage (e.g. `transcript`, `userNotes`, etc.)
- Return partial results via Server-Sent Events (SSE)

[Yogurt Worker](https://github.com/jonesphillip/yogurt-worker) is a working implementation you can deploy in your Cloudflare account.

Optional: Configure Cloudflare Access service tokens for additional security.

## Permissions

The app requires the following permissions:

- Microphone access for audio input
- System Audio Recording Only permission for system audio capture
- Documents folder access for note storage

These permissions will be requested on first use.

## Acknowledgments

- [AudioCap](https://github.com/insidegui/AudioCap) - System audio capture functionality
- [Cloudflare Workers](https://workers.cloudflare.com/)

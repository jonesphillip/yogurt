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
- Transcript-aware note enhancement
  - Assumes that you know and are taking note of the key points in meetings and fills out details you may have missed after your meeting
  - Improves note structure and format
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

The app requires a [Cloudflare Worker](https://developers.cloudflare.com/workers/) with two endpoints:

- `/transcribe`: Handles audio transcription
- `/enhance`: Processes and enhances notes

The Worker should accept:
- Audio data in WAV format for transcription
- JSON payloads containing note content and transcripts for enhancement

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

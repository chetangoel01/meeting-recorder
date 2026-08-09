# Meeting Recorder

Meeting Recorder is a native macOS utility that detects meeting-client audio activity, records both sides of the call, and sends the audio to OpenRouter for plain transcription. Its primary controls expand from the MacBook camera notch.

The app icon uses the same visual language as the overlay: a light blue waveform wrapped around a coral recording dot on a warm, friendly background. The complete macOS icon set lives in the asset catalog.

There is no transcript analysis, bot participant, hosted backend, or subscription. The app stores the OpenRouter key in Keychain and keeps meeting audio locally until transcription succeeds.

## Current scope

- Detects Zoom, Microsoft Teams, Webex, and FaceTime native clients. Audio helper processes are folded into one stable client identity so a single call cannot queue duplicate prompts.
- Treats sustained, simultaneous microphone and output activity in any installed web browser as a possible web meeting. Browser helper processes are mapped back to their host app; the device-level fallback is limited to the frontmost browser while it is also producing audio.
- Optionally uses Google Meet, Zoom, Teams, Webex, and FaceTime calendar links as a backup prompt.
- Displays Record, Stop, processing, completion, and recovery states around the camera notch.
- Expands into narrow left and right wings around the physical notch instead of dropping a panel below it. Click the upward chevron during recording—or drag upward anywhere on the overlay—to tuck active controls away. Tucked mode keeps only the red recording light, microphone mute, and Stop; click the red light to restore the full controls. Processing states use a small handle.
- During recording, microphone and call-audio buttons independently include or exclude each source from the saved recording.
- Captures system audio and microphone samples directly through ScreenCaptureKit, then writes independent two-minute M4A recovery chunks instead of relying on ScreenCaptureKit's recording-output wrapper.
- Splits long recordings into eight-minute M4A chunks before transcription to reduce provider timeouts.
- Stores transcripts as readable Markdown in `~/Library/Application Support/Meeting Recorder/Transcripts`.
- Retains source audio after any recording or transcription failure.

## Requirements

- macOS 15 or later. The app is being developed and tested on macOS 27 Golden Gate beta.
- Xcode 26 or later.
- An OpenRouter API key with access to a speech-to-text model.

The default model is `openai/whisper-large-v3`. You can change the model identifier in Settings.

## Build and run

1. Open `MeetingRecorder.xcodeproj` in Xcode.
2. Select the MeetingRecorder scheme and your Mac as the destination.
3. The project uses the owner's Apple Development team so macOS privacy grants persist across local updates. Choose your own Development Team under Signing & Capabilities if you build it on another account.
4. Build and run.
5. Enter your OpenRouter API key in Settings.
6. Grant Microphone and Screen & System Audio Recording access. Settings includes shortcuts to the matching macOS Privacy panes if a request was previously denied.
7. If calendar backup is enabled, grant Calendar access from the Reliability section.
8. Restart the app if macOS requests it after screen-recording permission is granted.
9. Keep Launch at login enabled so meeting detection is always running.

The notch prompt appears when a supported native client starts audio activity or when a browser has sustained microphone and output activity. Choose **Not a meeting** to suppress the prompt until that audio session ends.

For browser meetings, the app now waits for both microphone activity and sustained browser output. Calendar backup remains important for meetings that begin muted or before another participant speaks.

## Privacy and consent

The app never records automatically. A visible red recording light remains at the notch until recording stops, including in the tucked recording state. You are responsible for obtaining any consent required in your location and by the meeting participants.

Audio and transcripts stay on this Mac except for audio chunks sent to OpenRouter for transcription. Audio is deleted after a successful transcript unless **Keep audio after successful transcription** is enabled.

## Reliability behavior

- If recording succeeds but the API key is missing, the audio is retained and the notch offers Retry.
- If OpenRouter or the network fails, the audio is retained and can be retried.
- The notch does not enter Recording until both microphone and system-audio sample flow is verified. If either stream or the file writer stops during a meeting, recording stops with a visible error and keeps the completed audio chunks.
- Before transcription, the saved media duration is checked against the visible recording timer. A silent early cutoff is reported as a failure instead of being uploaded as if it were complete.
- New meeting detections replace old completion/error banners and are queued while saving or transcribing, so status UI cannot swallow the next meeting prompt.
- Calendar backup covers supported meeting links when a browser or native client has not yet opened its microphone. Calendar and audio detections for the same active call are coalesced instead of queuing a second prompt.
- Calendar monitoring resumes when access is granted in System Settings, and unsaved EventKit entries are deduplicated so they cannot re-prompt every polling interval.
- Manual recording is always available from the menu-bar item.
- Saved transcript duration comes from the finalized recording itself, excluding upload and transcription time.
- Turning the Mac's speaker volume down or using headphones does not remove call audio from the capture stream. Muting or pausing the meeting's incoming audio at its source does; use the speaker button in Meeting Recorder when you intentionally want to exclude call audio from the saved file.

## Development

The checked-in Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). Regenerate it after changing targets or build settings:

```sh
xcodegen generate
```

Run the focused test suite with:

```sh
xcodebuild test -project MeetingRecorder.xcodeproj -scheme MeetingRecorder -destination 'platform=macOS'
```

## Known limitations

- Browser detection requires simultaneous input and output, so a meeting that starts completely silent may rely on its calendar prompt or appear only when call audio begins.
- Recording includes all system audio playing on the selected display while capture is active. This avoids missing browser helper-process audio, but unrelated app sounds during the meeting can be included.
- The currently open two-minute recovery chunk still needs normal finalization. If the app or Mac crashes, earlier finalized chunks remain in the hidden capture work directory, but automatic crash-recovery UI is not yet implemented.
- Golden Gate is beta software. Audio-process behavior should be retested after each major beta update.

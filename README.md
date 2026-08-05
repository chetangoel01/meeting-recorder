# Meeting Recorder

Meeting Recorder is a native macOS utility that prompts when a meeting client or browser starts using the microphone, records both sides of the call, and sends the audio to OpenRouter for plain transcription. Its primary controls expand from the MacBook camera notch.

There is no transcript analysis, bot participant, hosted backend, or subscription. The app stores the OpenRouter key in Keychain and keeps meeting audio locally until transcription succeeds.

## Current scope

- Detects Zoom, Microsoft Teams, Webex, and FaceTime native clients.
- Treats microphone activity in any installed web browser as a possible web meeting. This favors an occasional extra prompt over a missed meeting.
- Optionally uses Google Meet, Zoom, Teams, Webex, and FaceTime calendar links as a backup prompt.
- Displays Record, Stop, processing, completion, and recovery states around the camera notch.
- Captures system audio and microphone audio through ScreenCaptureKit.
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
3. Choose a Development Team under Signing & Capabilities if Xcode requests one.
4. Build and run.
5. Enter your OpenRouter API key in Settings.
6. Grant Microphone and Screen & System Audio Recording access.
7. Restart the app if macOS requests it after screen-recording permission is granted.
8. Keep Launch at login enabled so meeting detection is always running.

The notch prompt appears when a supported native client starts audio activity or when any browser starts microphone capture. Choose **Not a meeting** to suppress the prompt until that audio session ends.

## Privacy and consent

The app never records automatically. A visible red recording state remains at the notch until recording stops. You are responsible for obtaining any consent required in your location and by the meeting participants.

Audio and transcripts stay on this Mac except for audio chunks sent to OpenRouter for transcription. Audio is deleted after a successful transcript unless **Keep audio after successful transcription** is enabled.

## Reliability behavior

- If recording succeeds but the API key is missing, the audio is retained and the notch offers Retry.
- If OpenRouter or the network fails, the audio is retained and can be retried.
- Calendar backup covers supported meeting links when a browser or native client has not yet opened its microphone.
- Manual recording is always available from the menu-bar item.

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

- Browser detection intentionally prompts for any new browser microphone session, including non-meeting voice sites.
- Process-filtered browser capture can include audio from other tabs belonging to that browser.
- ScreenCaptureKit writes a minimal video container during capture and converts it to M4A when recording stops.
- Golden Gate is beta software. Audio-process behavior should be retested after each major beta update.

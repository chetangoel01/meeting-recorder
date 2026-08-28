# Meeting Recorder Design System

## Theme

The primary surface is a compact, opaque notch extension used during video calls in varied ambient light. It uses a near-black neutral that visually joins the physical camera housing and remains legible in both light and dark desktop environments.

## Color

- Notch surface: `oklch(0.13 0.008 265)`
- Elevated surface: `oklch(0.19 0.010 265)`
- Primary text: `oklch(0.94 0.006 265)`
- Secondary text: `oklch(0.70 0.010 265)`
- Recording: `oklch(0.64 0.20 25)`
- Action: `oklch(0.72 0.13 235)`
- Success: `oklch(0.72 0.14 150)`
- Warning: `oklch(0.80 0.13 82)`

Use recording red only for active capture and stop controls. Use blue only for the primary affirmative action. State is always reinforced with text and iconography.

## App Icon

The app icon is deliberately lighter than the recording overlay: one continuous sky-blue waveform wrapped around a coral recording dot on a warm cream superellipse. The mark stays to two shapes so it remains recognizable at menu and Dock sizes. Production sizes and the 1024-point source are kept together in `MeetingRecorder/Resources/Assets.xcassets/AppIcon.appiconset`.

## Typography

Use the macOS system font. The notch uses 11 to 13 point labels with semibold emphasis for the active state or meeting source. Transcript history uses native body, headline, and caption styles so Dynamic Type and accessibility settings remain effective.

## Shape and Elevation

- The notch surface has square top corners and 18 to 22 point bottom corners, visually extending the camera housing.
- Compact buttons use native capsule shapes.
- Avoid nested cards. Transcript rows use spacing and separators.
- The overlay is opaque by default. Reduced transparency therefore does not materially change it.

## Motion

- State changes use a critically damped spring with approximately 0.32 second response and no overshoot.
- The surface expands horizontally into left and right wings around the physical notch. It moves upward along the same path when dismissed or tucked away.
- Reduced Motion replaces geometry animation with a short opacity transition.
- No looping decorative animation. The recording waveform reflects real microphone level when available; otherwise show a static recording mark.

## Components

### Idle notch

The idle surface matches the measured camera housing instead of extending beyond it. It should visually disappear into the physical notch; prompts and active states provide the expansion and controls. A Mac without that housing has nothing for it to disappear into, so the idle surface alone is optional: switched off, the overlay stays off screen until a state needs it and shrinks back into the notch on its way out. Every other state is unchanged.

### Meeting prompt

Shows the detected client, the question “Record this meeting?”, a primary Record action, and a secondary Not a meeting action. Content occupies left and right wings beside the physical notch; the prompt extends no more than a few points below the menu-bar height.

### Recording state

Shows an explicit recording label, elapsed time, source client, a visible minimize chevron, microphone inclusion, call-audio inclusion, and Stop action. The tucked variant retains only the red recording light, microphone mute, and Stop; the light restores the full controls. The visible state must remain present on every Space. The app enters this state only after microphone and system-audio sample flow has been verified; a red recording indicator must never represent an unverified capture pipeline.

### Notch gesture

An upward drag tracks the pointer directly and returns with a critically damped spring when it does not cross the threshold. On a prompt, committing the gesture means Not a meeting and suppresses that audio session. During capture, it switches to the recording safety strip without changing the operation. During processing, it leaves a small clickable handle below the notch. Completion and error states dismiss through the same upward path.

### Analyzing state

After transcription the notch shows an Analyzing state while the LLM writes the note's summary sections. It uses the same quiet status treatment as Saving; the transcript is already safe on disk before this state begins.

### Processing state

Shows whether the app is saving audio or transcribing. Processing may continue after the notch collapses, but status remains available from the menu bar.

### Error state

Explains the failed step in plain language and offers one relevant recovery action. Locally retained audio is stated explicitly. Capture-health and saved-duration failures take precedence over a misleading success state.

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

## Typography

Use the macOS system font. The notch uses 11 to 13 point labels with semibold emphasis for the active state or meeting source. Transcript history uses native body, headline, and caption styles so Dynamic Type and accessibility settings remain effective.

## Shape and Elevation

- The notch surface has square top corners and 18 to 22 point bottom corners, visually extending the camera housing.
- Compact buttons use native capsule shapes.
- Avoid nested cards. Transcript rows use spacing and separators.
- The overlay is opaque by default. Reduced transparency therefore does not materially change it.

## Motion

- State changes use a critically damped spring with approximately 0.32 second response and no overshoot.
- The surface expands downward from the physical notch and collapses along the same path.
- Reduced Motion replaces geometry animation with a short opacity transition.
- No looping decorative animation. The recording waveform reflects real microphone level when available; otherwise show a static recording mark.

## Components

### Idle notch

A narrow extension beneath the camera housing. It remains visually quiet and can be clicked to expose manual recording and status.

### Meeting prompt

Shows the detected client, the question “Record this meeting?”, a primary Record action, and a secondary Not a meeting action.

### Recording state

Shows an explicit recording label, elapsed time, source client, and Stop action. The visible state must remain present on every Space.

### Processing state

Shows whether the app is saving audio or transcribing. Processing may continue after the notch collapses, but status remains available from the menu bar.

### Error state

Explains the failed step in plain language and offers one relevant recovery action. Locally retained audio is stated explicitly.

# Design overview

The app's register is native macOS utility: system fonts, standard controls, restrained
color, the tool disappearing into the task. That register is settled — the question this
document answers is how to add feature depth without breaking it.

## The principle

"Clean" and "feature-rich" only conflict when features are surfaced with *more chrome* —
extra buttons, panels, badges. Native macOS resolves this differently: feature depth lives
in **standard mechanisms**, each with an established home:

| Mechanism | What belongs there |
| --- | --- |
| Toolbar | The 2–3 actions used every session (tab switch, copy, import) |
| Context menus | Per-item verbs (move, rename, delete, copy) |
| Main menu + shortcuts | Everything, redundantly — ⌘F, ⌘⌫, File → Import |
| Drag and drop | Import (files onto the window), filing (rows onto folders) |
| Info popover / inspector | Metadata that informs but isn't read every time (cost, source, attendees, file paths) |
| List-row states | Pipeline visibility (processing, failed) in the library itself |
| Empty / error states | Teaching the interface, offering the recovery action in place |

A feature is an afterthought when it exists in the data model or pipeline but has no home
in any of these. That — not missing chrome — is the gap to close.

## What's settled (don't relitigate)

- Notch HUD for capture states; dark, compact, capsule buttons. Its own register on purpose.
- Library: NavigationSplitView, Mail-style rows, toolbar-native controls, 640pt reading measure.
- Settings: three-tab native TabView, grouped forms.
- One accent color (system), used for primary actions, selection, "Me" speaker, checked items only.
- Notes and transcript are separate documents with a tab switch; notes are the primary face.

## Gaps, ranked

### Tier 1 — features that exist but have no UI home

1. **Analysis can't be re-run.** A failed analysis writes an italic apology into the note
   body; editing the prompt does nothing for existing meetings. Needs a *Regenerate notes*
   action (detail toolbar overflow + context menu), and failed analysis should render as a
   proper in-place error state with a Retry button, not body text.
2. **The pipeline is invisible in the library.** During transcription/analysis a meeting
   simply doesn't exist in the list; the menu bar icon only changes while recording. A
   processing meeting should appear as a list row (title, progress spinner, no selection
   into a half-built note), and the menu bar icon should reflect transcribing/analyzing.
   This is what makes import feel first-class: you import, you see it land.
3. **Import has one door.** Add drag-and-drop of audio/transcript files onto the library
   window and a File → Import Meeting… menu command. The toolbar button stays.
4. **No rename.** Meetings can't be retitled (LLM titles are good but not always right);
   folders can't be renamed or deleted. Double-click/Return to rename in list and sidebar,
   context menus on folder rows.
5. **Cost and metadata are captured but never shown.** `openrouter_cost_usd`, source,
   file locations live in frontmatter only. One ⓘ info popover on the detail toolbar:
   recorded, duration, source, folder, cost, transcript/audio links. Keeps the header to
   title + one quiet line.
6. **No keyboard/menu layer.** ⌘F focus search, ⌘⌫ move to Trash, ⌘1/⌘2 Notes/Transcript
   tabs, plus a real File/Edit/View command set. Invisible until wanted — the most native
   feature surface there is.

### Tier 2 — new capability (each is its own project; flag before building)

7. **Audio playback.** Audio is retained but unplayable in-app. Inline player in the
   detail view; transcript timestamps seek. This is the Otter-defining feature and the
   largest build (player UI + timestamp→offset mapping).
8. **Interactive action items.** Checkboxes render but can't be checked. Checking should
   write back to the note file — touches the storage format, so design the write-back
   contract first. A cross-meeting "Action items" sidebar view only makes sense after this.
9. **Attendees as data.** Calendar attendees currently feed the analysis prompt and are
   discarded. Persist them in frontmatter, show in the info popover. Small model change,
   do it alongside #5.
10. **Note editing.** Notes are read-only in-app. Cheap version: *Edit in default editor*
    (files are Markdown on disk — lean on that). In-app editing is a much bigger commitment;
    don't take it on until reading-mode gaps above are closed.

## Non-goals

Live transcription, meeting-bot joins, collaboration/sharing, theming, custom controls
where a standard one exists, and any dashboard/analytics surface. When a standard AppKit
affordance exists for a task, use it — familiarity is the feature.

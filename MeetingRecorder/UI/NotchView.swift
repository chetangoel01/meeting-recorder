import SwiftUI

struct NotchView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragOffset: CGFloat = 0

    private let notchGap: CGFloat = 204
    private let surface = Color(red: 0.018, green: 0.020, blue: 0.026)
    private let elevated = Color(red: 0.055, green: 0.060, blue: 0.074)
    private let primaryText = Color(red: 0.94, green: 0.94, blue: 0.96)
    private let secondaryText = Color(red: 0.67, green: 0.68, blue: 0.73)
    private let recordingColor = Color(red: 0.92, green: 0.20, blue: 0.22)
    private let warningColor = Color(red: 0.98, green: 0.70, blue: 0.22)
    private let actionColor = Color(red: 0.18, green: 0.58, blue: 0.88)

    var body: some View {
        ZStack {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 12,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(surface)

            if model.notchCollapsed, !model.phase.isIdle {
                collapsedContent
            } else {
                content
            }
        }
        .contentShape(Rectangle())
        .offset(y: dragOffset)
        .simultaneousGesture(dismissGesture)
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 1),
            value: model.phase
        )
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 1),
            value: model.notchCollapsed
        )
        .preferredColorScheme(.dark)
        .accessibilityHint(model.phase.isIdle ? "" : "Drag upward to tuck into the notch")
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            EmptyView()

        case let .prompt(candidate):
            wingLayout {
                HStack(spacing: 8) {
                    sourceIcon(candidate)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Record this meeting?")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(primaryText)
                        Text(candidate.appName)
                            .font(.system(size: 9))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                    }
                }
            } right: {
                HStack(spacing: 6) {
                    actionButton("Not a meeting", action: model.dismissPrompt)
                    primaryButton(
                        "Record",
                        systemImage: "record.circle",
                        action: model.recordPromptedMeeting
                    )
                }
            }

        case let .preparing(candidate):
            wingLayout {
                statusRow(title: "Preparing \(candidate.appName)…")
            } right: {
                EmptyView()
            }

        case let .recording(session):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                wingLayout {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(recordingColor)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Recording")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(primaryText)
                            if let warning = model.recordingWarning {
                                Text(warning)
                                    .font(.system(size: 9))
                                    .foregroundStyle(warningColor)
                                    .lineLimit(1)
                            } else {
                                Text(session.candidate.appName)
                                    .font(.system(size: 9))
                                    .foregroundStyle(secondaryText)
                                    .lineLimit(1)
                            }
                        }
                        iconButton(
                            "Minimize recording controls",
                            systemImage: "chevron.up",
                            action: model.collapseOrDismissNotch
                        )
                    }
                } right: {
                    HStack(spacing: 5) {
                        Text(Self.elapsedString(context.date.timeIntervalSince(session.startedAt)))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(primaryText)
                            .contentTransition(.numericText())
                        sourceToggle(
                            label: model.microphoneIncluded
                                ? "Exclude microphone from recording"
                                : "Include microphone in recording",
                            systemImage: model.microphoneIncluded ? "mic.fill" : "mic.slash.fill",
                            isIncluded: model.microphoneIncluded,
                            action: model.toggleMicrophoneIncluded
                        )
                        sourceToggle(
                            label: model.systemAudioIncluded
                                ? "Exclude call audio from recording"
                                : "Include call audio in recording",
                            systemImage: model.systemAudioIncluded
                                ? "speaker.wave.2.fill"
                                : "speaker.slash.fill",
                            isIncluded: model.systemAudioIncluded,
                            action: model.toggleSystemAudioIncluded
                        )
                        stopButton
                    }
                }
            }

        case .saving:
            wingLayout {
                statusRow(title: "Saving meeting audio…")
            } right: {
                EmptyView()
            }

        case .analyzing:
            wingLayout {
                statusRow(title: "Analyzing meeting…")
            } right: {
                EmptyView()
            }

        case let .transcribing(progress):
            wingLayout {
                HStack(spacing: 7) {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .tint(actionColor)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Transcribing")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(primaryText)
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 9))
                            .foregroundStyle(secondaryText)
                    }
                }
            } right: {
                EmptyView()
            }

        case let .completed(record):
            wingLayout {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.34, green: 0.78, blue: 0.52))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Transcript saved")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(primaryText)
                        Text(record.title)
                            .font(.system(size: 9))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                    }
                }
            } right: {
                HStack(spacing: 5) {
                    actionButton("Copy") { model.copyTranscript(record) }
                    iconButton("Dismiss", systemImage: "xmark", action: model.dismissStatus)
                }
            }

        case let .failed(message, audioURL):
            wingLayout {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.24))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Recording needs attention")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(primaryText)
                        Text(message)
                            .font(.system(size: 8.5))
                            .foregroundStyle(secondaryText)
                            .lineLimit(2)
                    }
                }
            } right: {
                HStack(spacing: 5) {
                    if let audioURL {
                        actionButton("Show audio") { model.revealAudio(audioURL) }
                        primaryButton(
                            "Retry",
                            systemImage: "arrow.clockwise",
                            action: model.retryTranscription
                        )
                    } else {
                        actionButton("Dismiss", action: model.dismissStatus)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var collapsedContent: some View {
        if model.phase.isRecording {
            compactRecordingContent
        } else {
            collapsedHandle
        }
    }

    private var compactRecordingContent: some View {
        wingLayout {
            Button(action: model.expandNotch) {
                Circle()
                    .fill(recordingColor)
                    .frame(width: 8, height: 8)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Show full recording controls")
            .accessibilityLabel("Show full recording controls")
        } right: {
            HStack(spacing: 5) {
                sourceToggle(
                    label: model.microphoneIncluded
                        ? "Mute microphone in recording"
                        : "Unmute microphone in recording",
                    systemImage: model.microphoneIncluded ? "mic.fill" : "mic.slash.fill",
                    isIncluded: model.microphoneIncluded,
                    action: model.toggleMicrophoneIncluded
                )
                stopButton
            }
        }
    }

    private var collapsedHandle: some View {
        VStack(spacing: 0) {
            Spacer()
            Capsule()
                .fill(actionColor)
                .frame(width: 34, height: 3)
                .padding(.bottom, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: model.expandNotch)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Show Meeting Recorder")
        .accessibilityAddTraits(.isButton)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragOffset) { value, offset, _ in
                guard abs(value.translation.height) > abs(value.translation.width),
                      value.translation.height < 0
                else { return }
                offset = value.translation.height
            }
            .onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                let projected = value.predictedEndTranslation.height
                if value.translation.height < -16 || projected < -34 {
                    model.collapseOrDismissNotch()
                }
            }
    }

    private func wingLayout<Left: View, Right: View>(
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) -> some View {
        HStack(spacing: 0) {
            left()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)

            Color.clear
                .frame(width: notchGap)
                .accessibilityHidden(true)

            right()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10)
        }
    }

    private func sourceIcon(_ candidate: MeetingCandidate) -> some View {
        Image(systemName: candidate.trigger == .browser ? "globe" : "video.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(actionColor)
            .frame(width: 24, height: 24)
            .background(elevated, in: Circle())
            .accessibilityHidden(true)
    }

    private func statusRow(title: String) -> some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.mini)
                .tint(actionColor)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(primaryText)
                .lineLimit(1)
        }
    }

    private func primaryButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(primaryText)
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(actionColor, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func actionButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(primaryText)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(elevated, in: Capsule())
    }

    private func iconButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(primaryText)
                .frame(width: 24, height: 24)
                .background(elevated, in: Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func sourceToggle(
        label: String,
        systemImage: String,
        isIncluded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isIncluded ? primaryText : secondaryText)
                .frame(width: 24, height: 24)
                .background(elevated, in: Circle())
                .overlay {
                    if !isIncluded {
                        Circle().stroke(Color.white.opacity(0.08), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var stopButton: some View {
        Button(action: model.stopRecording) {
            Image(systemName: "stop.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(primaryText)
                .frame(width: 24, height: 24)
                .background(recordingColor, in: Circle())
        }
        .buttonStyle(.plain)
        .help("Stop recording")
        .accessibilityLabel("Stop recording")
    }

    private static func elapsedString(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}

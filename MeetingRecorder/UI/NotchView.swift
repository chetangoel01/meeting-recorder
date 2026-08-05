import SwiftUI

struct NotchView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let surface = Color(red: 0.018, green: 0.020, blue: 0.026)
    private let elevated = Color(red: 0.055, green: 0.060, blue: 0.074)
    private let primaryText = Color(red: 0.94, green: 0.94, blue: 0.96)
    private let secondaryText = Color(red: 0.67, green: 0.68, blue: 0.73)
    private let recordingColor = Color(red: 0.92, green: 0.20, blue: 0.22)
    private let actionColor = Color(red: 0.18, green: 0.58, blue: 0.88)

    var body: some View {
        ZStack(alignment: .bottom) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 22,
                bottomTrailingRadius: 22,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(surface)

            content
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.14) : .spring(response: 0.32, dampingFraction: 1),
            value: model.phase
        )
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            EmptyView()

        case let .prompt(candidate):
            HStack(spacing: 12) {
                sourceIcon(candidate)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Record this meeting?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(primaryText)
                    Text(candidate.appName)
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                actionButton("Not a meeting", action: model.dismissPrompt)
                primaryButton("Record", systemImage: "record.circle", action: model.recordPromptedMeeting)
            }

        case let .preparing(candidate):
            statusRow(icon: "waveform", title: "Preparing \(candidate.appName)…")

        case let .recording(session):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 10) {
                    Circle()
                        .fill(recordingColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Recording")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(primaryText)
                        Text(session.candidate.appName)
                            .font(.system(size: 10))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(Self.elapsedString(context.date.timeIntervalSince(session.startedAt)))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(primaryText)
                        .contentTransition(.numericText())
                    stopButton
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Recording \(session.candidate.appName), \(Self.elapsedString(context.date.timeIntervalSince(session.startedAt))) elapsed")
            }

        case .saving:
            statusRow(icon: "internaldrive", title: "Saving meeting audio…")

        case let .transcribing(progress):
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(actionColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcribing")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(primaryText)
                    Text("\(Int(progress * 100))% complete")
                        .font(.system(size: 10))
                        .foregroundStyle(secondaryText)
                }
                Spacer()
            }

        case let .completed(record):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.34, green: 0.78, blue: 0.52))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Transcript saved")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(primaryText)
                    Text(record.title)
                        .font(.system(size: 10))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                actionButton("Copy") { model.copyTranscript(record) }
                iconButton("Dismiss", systemImage: "xmark", action: model.dismissStatus)
            }

        case let .failed(message, audioURL):
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.24))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording needs attention")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(primaryText)
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                if let audioURL {
                    actionButton("Show audio") { model.revealAudio(audioURL) }
                    primaryButton("Retry", systemImage: "arrow.clockwise", action: model.retryTranscription)
                } else {
                    actionButton("Dismiss", action: model.dismissStatus)
                }
            }
        }
    }

    private func sourceIcon(_ candidate: MeetingCandidate) -> some View {
        Image(systemName: candidate.trigger == .browser ? "globe" : "video.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(actionColor)
            .frame(width: 28, height: 28)
            .background(elevated, in: Circle())
            .accessibilityHidden(true)
    }

    private func statusRow(icon: String, title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(actionColor)
            Image(systemName: icon)
                .foregroundStyle(secondaryText)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(primaryText)
                .lineLimit(1)
            Spacer()
        }
    }

    private func primaryButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(primaryText)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(actionColor, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func actionButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(primaryText)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(elevated, in: Capsule())
    }

    private func iconButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(primaryText)
                .frame(width: 28, height: 28)
                .background(elevated, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var stopButton: some View {
        Button(action: model.stopRecording) {
            Label("Stop", systemImage: "stop.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(primaryText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(recordingColor, in: Capsule())
        }
        .buttonStyle(.plain)
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

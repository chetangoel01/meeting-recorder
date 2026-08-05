import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class NotchPanelController {
    private let model: AppModel
    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        observeModel()
    }

    func show() {
        updateFrame(for: model.phase, animated: false)
        panel.orderFrontRegardless()
    }

    private func configurePanel() {
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
#if DEBUG
        panel.sharingType = .readOnly
#else
        panel.sharingType = .none
#endif
        panel.contentView = NSHostingView(rootView: NotchView(model: model))
    }

    private func observeModel() {
        model.$phase
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                self?.updateFrame(for: phase, animated: true)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateFrame(for: self.model.phase, animated: false)
            }
            .store(in: &cancellables)
    }

    private func updateFrame(for phase: RecorderPhase, animated: Bool) {
        guard let screen = Self.preferredScreen else { return }
        let notch = Self.notchMetrics(for: screen)
        let size = Self.size(for: phase, notchWidth: notch.width, notchHeight: notch.height)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.hasShadow = phase != .idle

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private static var preferredScreen: NSScreen? {
        NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("built-in") }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private static func notchMetrics(for screen: NSScreen) -> (width: CGFloat, height: CGFloat) {
        let fallback = (width: CGFloat(204), height: CGFloat(max(32, screen.safeAreaInsets.top)))
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX
        else {
            return fallback
        }
        return (
            width: right.minX - left.maxX,
            height: max(screen.frame.maxY - left.maxY, screen.safeAreaInsets.top)
        )
    }

    private static func size(
        for phase: RecorderPhase,
        notchWidth: CGFloat,
        notchHeight: CGFloat
    ) -> CGSize {
        let idleWidth = max(notchWidth + 18, 218)
        let compactHeight = max(notchHeight + 10, 42)

        switch phase {
        case .idle:
            return CGSize(width: idleWidth, height: compactHeight)
        case .prompt:
            return CGSize(width: max(idleWidth, 430), height: max(notchHeight + 78, 116))
        case .preparing, .saving:
            return CGSize(width: max(idleWidth, 312), height: max(notchHeight + 42, 76))
        case .recording:
            return CGSize(width: max(idleWidth, 342), height: max(notchHeight + 42, 76))
        case .transcribing:
            return CGSize(width: max(idleWidth, 350), height: max(notchHeight + 44, 78))
        case .completed:
            return CGSize(width: max(idleWidth, 360), height: max(notchHeight + 48, 82))
        case .failed:
            return CGSize(width: max(idleWidth, 450), height: max(notchHeight + 82, 120))
        }
    }
}

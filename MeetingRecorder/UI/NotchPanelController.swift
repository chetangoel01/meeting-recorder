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
        applyCurrentVisibility(animated: false)
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
        Publishers.CombineLatest3(
            model.$phase.removeDuplicates(),
            model.$notchCollapsed.removeDuplicates(),
            model.settings.$showsIdleNotchBar.removeDuplicates()
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, collapsed, showsIdleBar in
                self?.applyVisibility(
                    phase: phase,
                    collapsed: collapsed,
                    showsIdleBar: showsIdleBar,
                    animated: true
                )
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyCurrentVisibility(animated: false)
            }
            .store(in: &cancellables)
    }

    private func applyCurrentVisibility(animated: Bool) {
        applyVisibility(
            phase: model.phase,
            collapsed: model.notchCollapsed,
            showsIdleBar: model.settings.showsIdleNotchBar,
            animated: animated
        )
    }

    private func applyVisibility(
        phase: RecorderPhase,
        collapsed: Bool,
        showsIdleBar: Bool,
        animated: Bool
    ) {
        guard NotchLayout.isOnScreen(phase: phase, showsIdleBar: showsIdleBar) else {
            // Leave along the path it arrived on: shrink back to the notch
            // first, then order out — unless a queued meeting has claimed the
            // panel by the time the animation lands.
            updateFrame(for: .idle, collapsed: false, animated: animated) { [weak self] in
                guard let self, !self.shouldBeOnScreen else { return }
                self.panel.orderOut(nil)
            }
            return
        }

        // Returning from hidden, seed the notch-sized frame before showing so
        // the overlay grows out of it instead of appearing at full width.
        if !panel.isVisible {
            updateFrame(for: .idle, collapsed: false, animated: false)
            panel.orderFrontRegardless()
        }
        updateFrame(for: phase, collapsed: collapsed, animated: animated)
    }

    private var shouldBeOnScreen: Bool {
        NotchLayout.isOnScreen(
            phase: model.phase,
            showsIdleBar: model.settings.showsIdleNotchBar
        )
    }

    private func updateFrame(
        for phase: RecorderPhase,
        collapsed: Bool,
        animated: Bool,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard let screen = Self.preferredScreen else {
            completion?()
            return
        }
        let notch = Self.notchMetrics(for: screen)
        let size = NotchLayout.size(
            for: phase,
            collapsed: collapsed,
            notchWidth: notch.width,
            notchHeight: notch.height
        )
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.hasShadow = phase != .idle

        let shouldAnimate = animated
            && panel.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: {
                MainActor.assumeIsolated { completion?() }
            }
        } else {
            panel.setFrame(frame, display: true)
            completion?()
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

}

struct NotchLayout {
    // The idle surface is there to disappear into a physical camera housing.
    // Without one it is a dark bar across the menu bar, so it can be switched
    // off — every active state still expands at the notch either way.
    static func isOnScreen(phase: RecorderPhase, showsIdleBar: Bool) -> Bool {
        showsIdleBar || !phase.isIdle
    }

    static func size(
        for phase: RecorderPhase,
        collapsed: Bool,
        notchWidth: CGFloat,
        notchHeight: CGFloat
    ) -> CGSize {
        if collapsed, phase.isRecording {
            return CGSize(width: max(notchWidth, 340), height: max(notchHeight + 4, 38))
        }
        if collapsed, !phase.isIdle {
            return CGSize(width: notchWidth + 44, height: notchHeight + 6)
        }

        switch phase {
        case .idle:
            return CGSize(width: notchWidth, height: notchHeight)
        case .prompt:
            return CGSize(width: max(notchWidth, 560), height: max(notchHeight + 4, 38))
        case .preparing, .saving:
            return CGSize(width: max(notchWidth, 420), height: max(notchHeight + 4, 38))
        case .recording:
            return CGSize(width: max(notchWidth, 520), height: max(notchHeight + 4, 38))
        case .transcribing, .analyzing:
            return CGSize(width: max(notchWidth, 440), height: max(notchHeight + 4, 38))
        case .completed:
            return CGSize(width: max(notchWidth, 500), height: max(notchHeight + 4, 38))
        case .failed:
            return CGSize(width: max(notchWidth, 650), height: max(notchHeight + 10, 44))
        }
    }
}

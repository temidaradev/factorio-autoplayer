import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
final class FactorioDesktop {
    static let bundleID = "com.factorio"
    static let frameLifetime: TimeInterval = 60

    struct Window: Equatable {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
    }

    struct Frame {
        let id: String
        let window: Window
        let geometry: FrameGeometry
        let capturedAt: TimeInterval
        let png: Data
    }

    struct ActionReport: Encodable {
        let completed: Int
        let requested: Int
        let error: String?
    }

    let allowsInput: Bool
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var latestFrame: Frame?

    init(allowsInput: Bool) {
        self.allowsInput = allowsInput
    }

    var status: [String: Bool] {
        [
            "factorioRunning": application != nil,
            "factorioInFront": NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleID,
            "screenRecordingGranted": CGPreflightScreenCaptureAccess(),
            "inputPermissionGranted": CGPreflightPostEventAccess(),
            "inputEnabledByOperator": allowsInput
        ]
    }

    func focus() throws {
        try checkInputPermission()
        guard let application else { throw PlayerError("Launch Factorio first.") }
        latestFrame = nil
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
            guard application.activate(options: []) else {
                throw PlayerError("macOS rejected activation. Bring Factorio to the foreground.")
            }
        }
    }

    func observe() async throws -> Frame {
        latestFrame = nil
        guard let currentWindow = gameWindow() else {
            throw PlayerError("Factorio needs a visible, nonminimized game window in the current Space.")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw PlayerError("macOS Screen Recording permission is required for the process running this player.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == currentWindow.id }) else {
            throw PlayerError("ScreenCaptureKit could not find the Factorio window.")
        }

        let bounds = currentWindow.bounds
        let scale = min(1, 1920 / max(bounds.width, bounds.height))
        let settings = captureSettings(bounds: bounds, scale: scale)
        settings.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: settings)
        } catch {
            // Some fullscreen game windows cannot be captured independently.
            guard let display = content.displays.first(where: { $0.frame.contains(bounds) }) else { throw error }
            let cropped = captureSettings(bounds: bounds, scale: scale)
            cropped.sourceRect = bounds.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let visibleWindow = SCContentFilter(display: display, including: [window])
            image = try await SCScreenshotManager.captureImage(contentFilter: visibleWindow, configuration: cropped)
        }
        guard gameWindow() == currentWindow else {
            throw PlayerError("The Factorio window moved or changed during capture. Observe again.")
        }

        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PlayerError("Could not create a PNG encoder.")
        }
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw PlayerError("Could not encode the frame.") }

        let frame = Frame(
            id: UUID().uuidString,
            window: currentWindow,
            geometry: FrameGeometry(bounds: bounds, width: image.width, height: image.height),
            capturedAt: ProcessInfo.processInfo.systemUptime,
            png: data as Data
        )
        latestFrame = frame
        return frame
    }

    private func captureSettings(bounds: CGRect, scale: CGFloat) -> SCStreamConfiguration {
        let settings = SCStreamConfiguration()
        settings.width = Int((bounds.width * scale).rounded())
        settings.height = Int((bounds.height * scale).rounded())
        settings.showsCursor = false
        return settings
    }

    func act(frameID: String, requests: [ActionRequest]) throws -> ActionReport {
        try checkInputPermission()
        guard let frame = latestFrame, frame.id == frameID,
              ProcessInfo.processInfo.systemUptime - frame.capturedAt <= Self.frameLifetime else {
            throw PlayerError("Observe again before sending input. Use the latest frame within 60 seconds.")
        }
        let actions = try PreparedAction.prepare(requests, geometry: frame.geometry)
        try checkTarget(frame.window)
        let pressedModifiers = CGEventSource.flagsState(.hidSystemState)
        let standardModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard pressedModifiers.intersection(standardModifiers).isEmpty,
              Button.allCases.allSatisfy({ !CGEventSource.buttonState(.hidSystemState, button: $0.native) })
        else {
            throw PlayerError("Release the physical mouse buttons and modifier keys before letting the player act.")
        }

        latestFrame = nil
        for (index, action) in actions.enumerated() {
            do {
                try checkTarget(frame.window)
                try perform(action, window: frame.window)
            } catch {
                return ActionReport(completed: index, requested: actions.count, error: error.localizedDescription)
            }
        }
        return ActionReport(completed: actions.count, requested: actions.count, error: nil)
    }

    private var application: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first { !$0.isTerminated }
    }

    private var windows: [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
    }

    private func bounds(of item: [String: Any]) -> CGRect? {
        guard let raw = item[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: raw as CFDictionary)
    }

    private func gameWindow() -> Window? {
        guard let pid = application?.processIdentifier else { return nil }
        return gameWindow(for: pid, in: windows)
    }

    private func gameWindow(for pid: pid_t, in visibleWindows: [[String: Any]]) -> Window? {
        for item in visibleWindows {
            guard item[kCGWindowOwnerPID as String] as? Int32 == pid,
                  item[kCGWindowLayer as String] as? Int == 0,
                  let id = item[kCGWindowNumber as String] as? CGWindowID,
                  let rect = bounds(of: item), rect.width >= 320, rect.height >= 200 else { continue }
            return Window(id: id, pid: pid, bounds: rect)
        }
        return nil
    }

    private func checkInputPermission() throws {
        guard allowsInput else { throw PlayerError("Start the MCP server with --allow-input to enable game controls.") }
        guard CGPreflightPostEventAccess() else {
            throw PlayerError("macOS Accessibility permission is required to post keyboard and mouse input.")
        }
    }

    private func checkTarget(_ window: Window, at point: CGPoint? = nil) throws {
        let visibleWindows = windows
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid,
              gameWindow(for: window.pid, in: visibleWindows) == window else {
            throw PlayerError("Factorio lost focus or its window changed. Observe again before resuming.")
        }
        if let point {
            let hit = visibleWindows.first {
                ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0.01
                    && ($0[kCGWindowLayer as String] as? Int ?? -1) >= 0
                    && bounds(of: $0)?.contains(point) == true
            }
            guard hit?[kCGWindowNumber as String] as? CGWindowID == window.id else {
                throw PlayerError("Another macOS window covers the intended input point.")
            }
        }
    }

    private func perform(_ action: PreparedAction, window: Window) throws {
        try withModifiers(action.modifiers) { activeFlags in
            let duration = action.durationMs
            switch action.operation {
            case .move(let point):
                try move(to: point, window: window, flags: activeFlags)
                try hold(duration, window: window, at: point)
            case .click(let point, let button):
                try move(to: point, window: window, flags: activeFlags)
                try hold(45, window: window, at: point)
                try withButton(button, at: point, flags: activeFlags) { _ in
                    try hold(duration, window: window, at: point)
                }
            case .drag(let start, let end):
                try move(to: start, window: window, flags: activeFlags)
                try hold(45, window: window, at: start)
                try withButton(.left, at: start, flags: activeFlags) { lastPoint in
                    let steps = max(4, duration / 30)
                    for step in 1...steps {
                        let progress = CGFloat(step) / CGFloat(steps)
                        let point = CGPoint(
                            x: start.x + (end.x - start.x) * progress,
                            y: start.y + (end.y - start.y) * progress
                        )
                        try hold(duration / steps, window: window, at: point)
                        try pointer(Button.left.events.drag, at: point, button: .left, flags: activeFlags).post(tap: .cghidEventTap)
                        lastPoint = point
                    }
                }
            case .scroll(let point, let ticks):
                try move(to: point, window: window, flags: activeFlags)
                try hold(35, window: window, at: point)
                guard let wheel = CGEvent(scrollWheelEvent2Source: eventSource, units: .line, wheelCount: 1,
                                          wheel1: ticks, wheel2: 0, wheel3: 0) else {
                    throw PlayerError("Could not construct a scroll event.")
                }
                wheel.location = point
                wheel.flags = []
                wheel.post(tap: .cghidEventTap)
                try hold(duration, window: window, at: point)
            case .key(let keys):
                try withKeys(keys, flags: activeFlags) {
                    try hold(duration, window: window)
                }
            case .wait:
                try hold(duration, window: window)
            case .text(let strokes):
                for (code, uppercase) in strokes {
                    try checkTarget(window)
                    try withModifiers(uppercase ? [.shift] : []) { active in
                        try withKeys([code], flags: active) {
                            Thread.sleep(forTimeInterval: 0.012)
                        }
                    }
                    Thread.sleep(forTimeInterval: 0.006)
                }
            }
        }
    }

    private func hold(_ milliseconds: Int, window: Window, at point: CGPoint? = nil) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(milliseconds) / 1_000
        var remaining = deadline - ProcessInfo.processInfo.systemUptime
        while remaining > 0 {
            Thread.sleep(forTimeInterval: min(remaining, 0.05))
            try checkTarget(window, at: point)
            remaining = deadline - ProcessInfo.processInfo.systemUptime
        }
    }

    private func move(to point: CGPoint, window: Window, flags: CGEventFlags) throws {
        try checkTarget(window, at: point)
        guard CGWarpMouseCursorPosition(point) == .success else {
            throw PlayerError("macOS could not move the foreground cursor.")
        }
        try pointer(.mouseMoved, at: point, button: .left, flags: flags).post(tap: .cghidEventTap)
    }

    private func pointer(
        _ type: CGEventType, at point: CGPoint, button: Button, flags: CGEventFlags
    ) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: button.native) else {
            throw PlayerError("Could not construct a pointer event.")
        }
        event.flags = flags
        if type != .mouseMoved {
            event.setIntegerValueField(.mouseEventButtonNumber, value: button.number)
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        return event
    }

    private func withButton(
        _ button: Button, at point: CGPoint, flags: CGEventFlags, _ body: (inout CGPoint) throws -> Void
    ) throws {
        let up = try pointer(button.events.up, at: point, button: button, flags: flags)
        var lastPoint = point
        try pointer(button.events.down, at: point, button: button, flags: flags).post(tap: .cghidEventTap)
        defer {
            up.location = lastPoint
            up.post(tap: .cghidEventTap)
        }
        try body(&lastPoint)
    }

    private func keyEvent(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else {
            throw PlayerError("Could not construct a keyboard event.")
        }
        event.flags = flags
        return event
    }

    private func withKeys(_ keys: [CGKeyCode], flags: CGEventFlags, _ body: () throws -> Void) throws {
        let releases = try keys.reversed().map { try keyEvent($0, down: false, flags: flags) }
        let presses = try keys.map { try keyEvent($0, down: true, flags: flags) }
        for event in presses { event.post(tap: .cghidEventTap) }
        defer { for event in releases { event.post(tap: .cghidEventTap) } }
        try body()
    }

    private func withModifiers(
        _ modifiers: [Modifier], _ body: (CGEventFlags) throws -> Void
    ) throws {
        var flags: CGEventFlags = []
        var presses: [CGEvent] = []
        var releases: [CGEvent] = []
        for modifier in modifiers {
            let release = try keyEvent(modifier.code, down: false, flags: flags)
            release.type = .flagsChanged
            releases.append(release)
            flags.insert(modifier.flag)
            let press = try keyEvent(modifier.code, down: true, flags: flags)
            press.type = .flagsChanged
            presses.append(press)
        }
        for event in presses { event.post(tap: .cghidEventTap) }
        defer { for event in releases.reversed() { event.post(tap: .cghidEventTap) } }
        try body(flags)
    }
}

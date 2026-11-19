import Carbon
import CoreGraphics
import Foundation

struct PlayerError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

struct Pixel: Codable, Equatable {
    let x: Int
    let y: Int
}

struct FrameGeometry: Equatable {
    let bounds: CGRect
    let width: Int
    let height: Int

    func desktopPoint(for pixel: Pixel) throws -> CGPoint {
        guard (0..<width).contains(pixel.x), (0..<height).contains(pixel.y) else {
            throw PlayerError("The point is outside the screenshot.")
        }
        let point = CGPoint(
            x: bounds.minX + (CGFloat(pixel.x) + 0.5) * bounds.width / CGFloat(width),
            y: bounds.minY + (CGFloat(pixel.y) + 0.5) * bounds.height / CGFloat(height)
        )
        guard bounds.insetBy(dx: 5, dy: 5).contains(point) else {
            throw PlayerError("Use a point at least five macOS points from the window edges.")
        }
        return point
    }
}

enum Button: String, CaseIterable, Codable {
    case left, right, middle

    var native: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }

    var events: (down: CGEventType, up: CGEventType, drag: CGEventType) {
        switch self {
        case .left: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        case .middle: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
    }

    var number: Int64 {
        Int64(native.rawValue)
    }
}

enum Modifier: String, CaseIterable, Codable {
    case shift, control

    var flag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .control: return .maskControl
        }
    }

    var code: CGKeyCode {
        switch self {
        case .shift: return CGKeyCode(kVK_Shift)
        case .control: return CGKeyCode(kVK_Control)
        }
    }
}

struct ActionRequest: Decodable {
    enum Kind: String, Decodable {
        case move, click, drag, scroll, key, wait, text
    }

    let type: Kind
    let at: Pixel?
    let to: Pixel?
    let button: Button?
    let key: String?
    let text: String?
    let ticks: Int?
    let modifiers: [Modifier]?
    let durationMs: Int?
}

struct PreparedAction {
    enum Operation {
        case move(CGPoint)
        case click(CGPoint, Button)
        case drag(CGPoint, CGPoint)
        case scroll(CGPoint, Int32)
        case key([CGKeyCode])
        case wait
        case text([(CGKeyCode, Bool)])
    }

    let operation: Operation
    let modifiers: [Modifier]
    let durationMs: Int

    static let maxActions = 12
    static let maxBatchMs = 4_000
    static let maxActionMs = 1_500
    static let maxTextLength = 64

    static func prepare(_ requests: [ActionRequest], geometry: FrameGeometry) throws -> [Self] {
        guard (1...maxActions).contains(requests.count) else {
            throw PlayerError("Send between 1 and \(maxActions) actions.")
        }
        let actions = try requests.map { try Self($0, geometry: geometry) }
        guard actions.reduce(0, { $0 + $1.durationMs + 75 }) <= maxBatchMs else {
            throw PlayerError("Reduce the batch to at most \(maxBatchMs) ms including input overhead.")
        }
        return actions
    }

    private init(_ request: ActionRequest, geometry: FrameGeometry) throws {
        let requestedModifiers = request.modifiers ?? []
        guard Set(requestedModifiers).count == requestedModifiers.count else {
            throw PlayerError("Each modifier can appear only once.")
        }

        func point(_ pixel: Pixel?) throws -> CGPoint {
            guard let pixel else { throw PlayerError("This action needs a screenshot point.") }
            return try geometry.desktopPoint(for: pixel)
        }

        let suggestedDuration: Int
        switch request.type {
        case .move:
            operation = .move(try point(request.at))
            suggestedDuration = 0
        case .click:
            operation = .click(try point(request.at), request.button ?? .left)
            suggestedDuration = 70
        case .drag:
            operation = .drag(try point(request.at), try point(request.to))
            suggestedDuration = 240
        case .scroll:
            guard let ticks = request.ticks, (-8...8).contains(ticks), ticks != 0 else {
                throw PlayerError("Scroll ticks must be between -8 and 8 and nonzero.")
            }
            operation = .scroll(try point(request.at), Int32(ticks))
            suggestedDuration = 0
        case .key:
            guard let key = request.key else { throw PlayerError("This action needs a key.") }
            let keys = key.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            let singles = keys.count == 1 && Self.keyCodes[key] != nil
            let diagonal = keys.count == 2 && Set(keys).count == 2
                && (keys.contains("w") || keys.contains("s"))
                && (keys.contains("a") || keys.contains("d"))
            guard singles || diagonal,
                  !requestedModifiers.contains(.control) || ["c", "f", "v", "x", "y", "z"].contains(key) else {
                throw PlayerError("Unsupported gameplay key or modifier combination.")
            }
            operation = .key(keys.compactMap { Self.keyCodes[$0] })
            suggestedDuration = 70
        case .wait:
            operation = .wait
            suggestedDuration = 250
        case .text:
            guard let input = request.text, (1...Self.maxTextLength).contains(input.count),
                  requestedModifiers.isEmpty, request.durationMs == nil else {
                throw PlayerError("Send 1 to \(Self.maxTextLength) plain text characters without modifiers or duration.")
            }
            let strokes = try input.map { character -> (CGKeyCode, Bool) in
                let lower = String(character).lowercased()
                if character == "_" { return (CGKeyCode(kVK_ANSI_Minus), true) }
                if character == "-" { return (CGKeyCode(kVK_ANSI_Minus), false) }
                if character == " " { return (CGKeyCode(kVK_Space), false) }
                guard let ascii = character.asciiValue,
                      (48...57).contains(ascii) || (65...90).contains(ascii) || (97...122).contains(ascii),
                      let code = Self.keyCodes[lower] else {
                    throw PlayerError("Text supports ASCII letters, digits, spaces, hyphens and underscores.")
                }
                return (code, (65...90).contains(ascii))
            }
            operation = .text(strokes)
            suggestedDuration = strokes.count * 18
        }

        if [.move, .scroll, .wait].contains(request.type), !requestedModifiers.isEmpty {
            throw PlayerError("Modifiers are supported only on clicks, drags and keys.")
        }
        let duration = request.durationMs ?? suggestedDuration
        guard (0...Self.maxActionMs).contains(duration) else {
            throw PlayerError("Duration must be between 0 and \(Self.maxActionMs) ms.")
        }
        if [.click, .key].contains(request.type), duration < 35 {
            throw PlayerError("A click or key hold needs at least 35 ms to reach the game.")
        }
        if request.type == .drag, duration < 120 {
            throw PlayerError("A drag needs at least 120 ms.")
        }
        modifiers = requestedModifiers
        durationMs = duration
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space, "escape": kVK_Escape, "return": kVK_Return, "tab": kVK_Tab,
        "delete": kVK_Delete, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "up": kVK_UpArrow, "down": kVK_DownArrow
    ].mapValues(CGKeyCode.init)
}

import Foundation

@MainActor
struct MCPServer {
    let desktop: FactorioDesktop

    func run() async {
        var initialized = false
        while let line = readLine() {
            guard !line.isEmpty else { continue }
            guard line.utf8.count <= 65_536,
                  let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else {
                write(error(id: NSNull(), code: -32700, message: "Invalid JSON-RPC input."))
                continue
            }
            guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
                write(error(id: message["id"] ?? NSNull(), code: -32600, message: "Invalid JSON-RPC request."))
                continue
            }
            guard let id = message["id"] else { continue }
            let parameters = message["params"] as? [String: Any] ?? [:]
            let result: [String: Any]
            switch method {
            case "initialize":
                let supported = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
                let requested = parameters["protocolVersion"] as? String
                result = [
                    "protocolVersion": supported.first { $0 == requested } ?? supported[0],
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "factorio-autoplayer", "version": "0.1.0"],
                    "instructions": """
                    Use this server only for the Factorio world the operator asked you to play.
                    Inspect a screenshot before sending each short batch. Observe again after input
                    to verify the game consumed it. Use normal gameplay and actual inventory.
                    An input receipt confirms event delivery to macOS; the screenshot proves the game result.
                    If Factorio loses focus, stop until the operator is ready.
                    """
                ]
                initialized = true
            case "ping":
                result = [:]
            case "tools/list" where initialized:
                result = ["tools": definitions]
            case "tools/call" where initialized:
                guard let name = parameters["name"] as? String,
                      definitions.contains(where: { $0["name"] as? String == name }) else {
                    write(error(id: id, code: -32602, message: "Unknown Factorio tool."))
                    continue
                }
                result = await call(name, arguments: parameters["arguments"] as? [String: Any] ?? [:])
            default:
                write(error(id: id, code: -32601, message: "Method unavailable: \(method)"))
                continue
            }
            write(["jsonrpc": "2.0", "id": id, "result": result])
        }
    }

    private func call(_ name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "factorio_status":
                return try Self.textResult(desktop.status)
            case "factorio_focus":
                try desktop.focus()
                return Self.messageResult("Activation requested. Check factorio_status, then observe.")
            case "factorio_observe":
                let frame = try await desktop.observe()
                let details = """
                frameId: \(frame.id)
                width: \(frame.geometry.width)
                height: \(frame.geometry.height)
                Coordinates are pixels from the top left of this image. The frame expires after 60 seconds.
                """
                return ["content": [
                    ["type": "text", "text": details],
                    ["type": "image", "mimeType": "image/png", "data": frame.png.base64EncodedString()]
                ]]
            case "factorio_act":
                let data = try JSONSerialization.data(withJSONObject: arguments)
                let request = try JSONDecoder().decode(Batch.self, from: data)
                let report = try desktop.act(frameID: request.frameId, requests: request.actions)
                return try Self.textResult(report, isError: report.error != nil)
            default:
                return Self.messageResult("Unknown Factorio tool.", isError: true)
            }
        } catch {
            let message = (error as? DecodingError).map { String(describing: $0) } ?? error.localizedDescription
            return Self.messageResult(message, isError: true)
        }
    }

    private struct Batch: Decodable {
        let frameId: String
        let actions: [ActionRequest]
    }

    private var definitions: [[String: Any]] {
        let empty: [String: Any] = ["type": "object", "additionalProperties": false]
        var tools: [[String: Any]] = [
            [
                "name": "factorio_status",
                "description": "Check whether Factorio is open and focused, and report required macOS permissions.",
                "inputSchema": empty,
                "annotations": ["readOnlyHint": true, "openWorldHint": false]
            ],
            [
                "name": "factorio_observe",
                "description": "Return a PNG of the visible Factorio window and the ID for the next action batch.",
                "inputSchema": empty,
                "annotations": ["readOnlyHint": true, "openWorldHint": false]
            ]
        ]
        guard desktop.allowsInput else { return tools }
        let pixel: [String: Any] = [
            "type": "object",
            "required": ["x", "y"],
            "properties": [
                "x": ["type": "integer", "minimum": 0],
                "y": ["type": "integer", "minimum": 0]
            ],
            "additionalProperties": false
        ]
        let step: [String: Any] = [
            "type": "object",
            "required": ["type"],
            "additionalProperties": false,
            "properties": [
                "type": ["enum": ["move", "click", "drag", "scroll", "key", "wait", "text"]],
                "at": pixel,
                "to": pixel,
                "button": ["enum": Button.allCases.map(\.rawValue)],
                "key": ["type": "string", "description": "Letters, digits, arrow keys, space, escape, return, tab, delete or a diagonal such as w+d."],
                "text": ["type": "string", "minLength": 1, "maxLength": PreparedAction.maxTextLength],
                "ticks": ["type": "integer", "minimum": -8, "maximum": 8, "description": "Positive scrolls up."],
                "modifiers": ["type": "array", "uniqueItems": true, "items": ["enum": Modifier.allCases.map(\.rawValue)]],
                "durationMs": ["type": "integer", "minimum": 0, "maximum": PreparedAction.maxActionMs]
            ]
        ]
        tools.append([
            "name": "factorio_focus",
            "description": "Request foreground focus for the already-open Factorio app when the operator is ready. Never launches the game.",
            "inputSchema": empty,
            "annotations": ["destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        ])
        tools.append([
            "name": "factorio_act",
            "description": """
            Play a short batch using normal Factorio controls. Use a fresh frameId. Move, click, drag
            and scroll need at; drag also needs to. Use right-click with a hold to mine. Click
            accepts shift or control for inventory transfers. A batch can contain at most 12
            actions and about four seconds of input, then must be visually verified. If the
            batch stops partway through, observe before continuing.
            """,
            "inputSchema": [
                "type": "object",
                "required": ["frameId", "actions"],
                "additionalProperties": false,
                "properties": [
                    "frameId": ["type": "string"],
                    "actions": ["type": "array", "minItems": 1, "maxItems": PreparedAction.maxActions, "items": step]
                ]
            ],
            "annotations": ["openWorldHint": false]
        ])
        return tools
    }

    private func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func write(_ response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }

    private static func textResult<Value: Encodable>(_ value: Value, isError: Bool = false) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return messageResult(String(decoding: data, as: UTF8.self), isError: isError)
    }

    private static func messageResult(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }
}

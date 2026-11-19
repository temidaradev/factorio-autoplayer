import Foundation

@main
struct FactorioPlayer {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            switch arguments {
            case ["doctor"]:
                let status = FactorioDesktop(allowsInput: false).status
                let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            case ["mcp"], ["mcp", "--allow-input"]:
                let desktop = FactorioDesktop(allowsInput: arguments.contains("--allow-input"))
                await MCPServer(desktop: desktop).run()
            case _ where arguments.count == 2 && arguments[0] == "snapshot":
                let frame = try await FactorioDesktop(allowsInput: false).observe()
                let destination = URL(fileURLWithPath: arguments[1])
                try frame.png.write(to: destination, options: .withoutOverwriting)
                print("\(frame.geometry.width)x\(frame.geometry.height) PNG saved to \(destination.path)")
            case [], ["--help"], ["-h"]:
                print("""
                factorio-player doctor
                factorio-player snapshot <new-png-path>
                factorio-player mcp [--allow-input]
                """)
            default:
                throw PlayerError("Unknown arguments. Run factorio-player --help.")
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}

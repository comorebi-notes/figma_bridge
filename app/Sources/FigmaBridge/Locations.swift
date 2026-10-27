import Foundation

// skill/paths.ts と同じ場所を使う
enum Locations {
    static let serverURL = URL(string: "http://127.0.0.1:3055")!
    static let skill = home(".claude/skills/figma_bridge")
    static let serverScript = skill.appending(path: "server.ts")
    static let clientScript = skill.appending(path: "client.ts")
    static let pluginManifest = skill.appending(path: "plugin/manifest.json")
    static let token = home("Library/Application Support/figma_bridge/.token")
    static let pid = home("Library/Application Support/figma_bridge/.pid")
    static let log = home("Library/Logs/figma_bridge/server.log")

    private static func home(_ path: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: path)
    }
}

// Finder やログイン時に開いたアプリはシェルの PATH を受け継がないため、bun の場所を順に探す
enum BunLocator {
    private static let savedPathKey = "bunPath"

    // メニューの「Bun の場所を選ぶ…」で選んだパス
    static var savedPath: String? {
        get { UserDefaults.standard.string(forKey: savedPathKey) }
        set { UserDefaults.standard.set(newValue, forKey: savedPathKey) }
    }

    static func find() -> URL? {
        let candidates = [
            savedPath,
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".bun/bin/bun").path,
        ].compactMap { $0 }
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(filePath: path)
        }
        return fromLoginShell()
    }

    // ログインシェルの PATH から探す。.zprofile などで PATH に足した場所にある bun も見つかる
    private static func fromLoginShell() -> URL? {
        let process = Process()
        process.executableURL = URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v bun"]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(filePath: path)
    }
}

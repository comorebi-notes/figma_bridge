import AppKit
import SwiftUI

@main
struct FigmaBridgeApp: App {
    private let bridge = BridgeController()

    var body: some Scene {
        MenuBarExtra {
            BridgeMenu(bridge: bridge)
        } label: {
            BridgeIcon(bridge: bridge)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct BridgeIcon: View {
    let bridge: BridgeController

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: bridge.status))
            .accessibilityLabel("Figma ブリッジ: \(bridge.statusText)")
    }
}

struct BridgeMenu: View {
    let bridge: BridgeController

    var body: some View {
        Text(bridge.statusText)
        if let ownerText = bridge.ownerText {
            Text(ownerText)
        }
        if let problem = bridge.problem {
            Text(problem)
        }
        if bridge.needsBunPath {
            Button("Bun の場所を選ぶ…") { bridge.chooseBun() }
        }
        Divider()
        if bridge.status == .stopped {
            Button("サーバーを起動") { bridge.start() }
        } else {
            Button("サーバーを停止") { bridge.stop() }
                .disabled(bridge.owner == .other || bridge.owner == nil)
        }
        Divider()
        Menu("最近の命令") {
            if bridge.commands.isEmpty {
                Text("まだ命令はありません")
            }
            ForEach(bridge.commands) { command in
                Text(command.summary)
            }
        }
        Button("ログを開く") { bridge.showLog() }
        Button("Figma プラグインのファイルを表示") { bridge.showPluginManifest() }
        Divider()
        Toggle("ログイン時に開く", isOn: Binding(get: { bridge.launchesAtLogin }, set: { bridge.setLaunchesAtLogin($0) }))
        Toggle("開いたらサーバーを起動", isOn: Binding(get: { bridge.startsServerOnLaunch }, set: { bridge.setStartsServerOnLaunch($0) }))
        Divider()
        Button("Figma ブリッジを終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

extension BridgeController {
    var statusText: String {
        switch status {
        case .stopped: "サーバーは止まっています"
        case .starting: "サーバーを起動しています"
        case .waiting: "プラグインの接続を待っています"
        case .connected(let fileName?): "接続中のファイル: \(fileName)"
        case .connected(nil): "プラグインが接続しています"
        case .unknown: "サーバーの状態を読めません"
        }
    }

    var ownerText: String? {
        switch owner {
        case .app: "このアプリが起動したサーバーです"
        case .claude: "Claude が起動したサーバーです"
        case .other: "ターミナルなどで起動したサーバーです。起動した側で止めてください"
        case nil: nil
        }
    }
}

extension BridgeController.Command {
    // 例: 10:32:05 成功 fill-icon-names（1.2 秒）
    var summary: String {
        let time = date.formatted(date: .omitted, time: .standard)
        let seconds = String(format: "%.1f 秒", Double(ms) / 1000)
        if ok {
            return "\(time) 成功 \(command)（\(seconds)）"
        }
        let reason = error ?? ""
        return "\(time) 失敗 \(command)（\(seconds)）: \(reason.count > 60 ? reason.prefix(60) + "…" : reason)"
    }
}

// 停止中は線だけ、プラグインを待っている間は点線、接続中は塗りつぶしの F で表す
@MainActor
enum MenuBarIcon {
    static func image(for status: BridgeController.Status) -> NSImage {
        switch status {
        case .stopped, .starting: stopped
        case .waiting, .unknown: waiting
        case .connected: connected
        }
    }

    private static let stopped = symbol("f.square")
    private static let connected = symbol("f.square.fill")
    // 点線の F の四角は SF Symbols にないため、点線の四角に F を重ねて描く
    private static let waiting: NSImage = {
        let square = symbol("square.dashed")
        let image = NSImage(size: square.size, flipped: false) { rect in
            square.draw(in: rect)
            let letter = NSAttributedString(string: "F", attributes: [.font: NSFont.systemFont(ofSize: rect.height * 0.55, weight: .semibold)])
            let size = letter.size()
            letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)!
    }
}

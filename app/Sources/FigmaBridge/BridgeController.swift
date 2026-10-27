import AppKit
import Observation
import ServiceManagement

// サーバーの起動と停止、状態の取得を受け持つ。状態は 2 秒ごとにサーバーへ問い合わせて更新する
@MainActor
@Observable
final class BridgeController {
    enum Status: Equatable {
        case stopped
        // このアプリが起動したサーバーが、まだ待ち受けを始めていない
        case starting
        // サーバーは起動していて、プラグインの接続を待っている
        case waiting
        // プラグインが接続している。値はプラグインが開いているファイルの名前
        case connected(fileName: String?)
        // 待ち受けているが、トークンが合わず状態を読めない
        case unknown
    }

    // サーバーを起動したもの
    enum Owner {
        case app, claude, other
    }

    // サーバーの GET /history が返す命令の記録
    struct Command: Decodable, Identifiable {
        let at: Double
        let command: String
        let ok: Bool
        let ms: Int
        let error: String?

        var id: Double { at }
        var date: Date { Date(timeIntervalSince1970: at / 1000) }
    }

    private struct StatusResponse: Decodable {
        let connected: Bool
        let fileName: String?
    }

    private struct HistoryResponse: Decodable {
        let history: [Command]
    }

    private enum RequestError: Error {
        case unreachable, rejected
    }

    private static let startsServerOnLaunchKey = "startsServerOnLaunch"

    private(set) var status = Status.stopped
    private(set) var owner: Owner?
    private(set) var commands: [Command] = []
    private(set) var problem: String?
    private(set) var needsBunPath = false
    private(set) var launchesAtLogin = false
    private(set) var startsServerOnLaunch: Bool

    private var server: Process?
    // サーバーの標準入力につないだまま持っておく。アプリが強制終了するとこれが閉じ、サーバーも止まる
    private var serverInput: Pipe?
    private var isStopping = false
    private let session = URLSession(configuration: .ephemeral)

    init() {
        startsServerOnLaunch = UserDefaults.standard.object(forKey: Self.startsServerOnLaunchKey) as? Bool ?? true
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopOwnServer() }
        }
        Task {
            await refresh()
            if startsServerOnLaunch && status == .stopped { start() }
            while true {
                try? await Task.sleep(for: .seconds(2))
                await refresh()
            }
        }
    }

    // MARK: 状態

    func refresh() async {
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        // トークンはサーバーの起動ごとに変わるため、毎回読み直す。画面やログには出さない
        let token = try? String(contentsOf: Locations.token, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        switch await get("/status", token: token, as: StatusResponse.self) {
        case .success(let response):
            status = response.connected ? .connected(fileName: response.fileName) : .waiting
            if case .success(let response) = await get("/history", token: token, as: HistoryResponse.self) {
                commands = response.history
            }
        case .failure(.rejected):
            status = .unknown
        case .failure(.unreachable):
            status = server?.isRunning == true ? .starting : .stopped
        }
        owner = currentOwner()
    }

    private func get<Response: Decodable>(_ path: String, token: String?, as type: Response.Type) async -> Result<Response, RequestError> {
        var request = URLRequest(url: Locations.serverURL.appending(path: path))
        request.timeoutInterval = 2
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: request) else { return .failure(.unreachable) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let value = try? JSONDecoder().decode(Response.self, from: data) else { return .failure(.rejected) }
        return .success(value)
    }

    private func currentOwner() -> Owner? {
        if status == .stopped { return nil }
        if server?.isRunning == true { return .app }
        return claudeServerPID() == nil ? .other : .claude
    }

    // client.ts の start が書いた .pid のプロセスが動いていれば、その PID を返す
    private func claudeServerPID() -> pid_t? {
        guard let text = try? String(contentsOf: Locations.pid, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              kill(pid, 0) == 0 else { return nil }
        return pid
    }

    // 起動や停止の直後は、2 秒を待たずに何度か状態を読み直す
    private func refreshSoon() {
        Task {
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(500))
                await refresh()
            }
        }
    }

    // MARK: 起動と停止

    func start() {
        guard server == nil, status == .stopped else { return }
        problem = nil
        guard let bun = BunLocator.find() else {
            needsBunPath = true
            problem = "Bun が見つかりません"
            return
        }
        needsBunPath = false
        guard FileManager.default.fileExists(atPath: Locations.serverScript.path) else {
            problem = "server.ts が見つかりません。~/.claude/skills/figma_bridge を確かめてください"
            return
        }
        do {
            let log = try openLogForAppend()
            let input = Pipe()
            let process = Process()
            process.executableURL = bun
            process.arguments = [Locations.serverScript.path, "--exit-on-stdin-close"]
            process.standardInput = input
            process.standardOutput = log
            process.standardError = log
            process.terminationHandler = { [weak self] process in
                let code = process.terminationStatus
                Task { @MainActor [weak self] in self?.serverDidExit(code: code) }
            }
            try process.run()
            try? log.close()
            server = process
            serverInput = input
            status = .starting
            owner = .app
            refreshSoon()
        } catch {
            problem = "サーバーを起動できません: \(error.localizedDescription)"
        }
    }

    // client.ts の start と同じく、ログに書き足す
    private func openLogForAppend() throws -> FileHandle {
        try FileManager.default.createDirectory(at: Locations.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(Locations.log.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func serverDidExit(code: Int32) {
        server = nil
        serverInput = nil
        if !isStopping && code != 0 {
            problem = "サーバーが止まりました（終了コード \(code)）。ログを確かめてください"
        }
        isStopping = false
        Task { await refresh() }
    }

    func stop() {
        problem = nil
        switch owner {
        case .app:
            isStopping = true
            server?.terminate()
        case .claude:
            // Claude が start で起動したサーバーは client.ts の stop で止め、.pid の確認と片付けを任せる
            runClient("stop")
        case .other, nil:
            return
        }
        refreshSoon()
    }

    private func runClient(_ argument: String) {
        guard let bun = BunLocator.find() else {
            needsBunPath = true
            problem = "Bun が見つかりません"
            return
        }
        let process = Process()
        process.executableURL = bun
        process.arguments = [Locations.clientScript.path, argument]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            problem = "client.ts を実行できません: \(error.localizedDescription)"
        }
    }

    // アプリを終了するときは、アプリが起動したサーバーだけを止める
    private func stopOwnServer() {
        guard let server, server.isRunning else { return }
        isStopping = true
        server.terminate()
    }

    // MARK: メニューの操作

    func showLog() {
        try? openLogForAppend().close()
        NSWorkspace.shared.open(Locations.log)
    }

    // ~/.claude は Finder で隠れているため、Figma で読み込むファイルを Finder に表示し、パスもコピーする。Figma の読み込み画面で ⌘⇧G を押して貼れる
    func showPluginManifest() {
        guard FileManager.default.fileExists(atPath: Locations.pluginManifest.path) else {
            problem = "プラグインのファイルが見つかりません。install.sh を実行してください"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Locations.pluginManifest.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([Locations.pluginManifest])
    }

    func chooseBun() {
        let panel = NSOpenPanel()
        panel.message = "bun の実行ファイルを選んでください"
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            problem = "選んだファイルは実行できません"
            return
        }
        BunLocator.savedPath = url.path
        start()
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            problem = nil
        } catch {
            problem = "ログイン項目を変更できません: \(error.localizedDescription)"
        }
        if SMAppService.mainApp.status == .requiresApproval {
            problem = "システム設定のログイン項目で、このアプリを許可してください"
            SMAppService.openSystemSettingsLoginItems()
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setStartsServerOnLaunch(_ enabled: Bool) {
        startsServerOnLaunch = enabled
        UserDefaults.standard.set(enabled, forKey: Self.startsServerOnLaunchKey)
    }
}

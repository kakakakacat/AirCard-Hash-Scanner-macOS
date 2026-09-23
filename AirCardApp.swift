import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"
    var id: String { rawValue }
}

private func tr(_ language: AppLanguage, _ english: String, _ chinese: String) -> String {
    language == .english ? english : chinese
}

struct WalletCard: Codable, Identifiable, Hashable {
    let hash: String
    let name: String?
    var customName: String?
    var id: String { hash }

    var displayName: String {
        let alias = customName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let alias, !alias.isEmpty { return alias }
        let scanned = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return scanned?.isEmpty == false ? scanned! : "Unnamed card"
    }
}

private struct ExportedCard: Encodable {
    let hash: String
    let name: String
}

struct DeviceInfo: Decodable {
    let connected: Bool
    let udid: String?
    let name: String?
    let version: String?
    let product: String?
    let error: String?
}

private struct ScanResponse: Decodable {
    let ok: Bool
    let cards: [WalletCard]?
    let error: String?
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var device: DeviceInfo?
    @Published var cards: [WalletCard] = []
    @Published var status = "Connect an unlocked iPhone by USB."
    @Published var isCheckingDevice = false
    @Published var isScanning = false
    @Published var errorMessage: String?

    private let scriptDirectory: URL
    private let savedCardsKey = "aircard.hash-scanner.cards"

    init() {
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("wallet_scanner.py").path) {
            scriptDirectory = resources
        } else {
            scriptDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        loadCards()
        refreshDevice()
    }

    var isConnected: Bool { device?.connected == true && device?.udid != nil }

    func refreshDevice() {
        guard !isCheckingDevice, !isScanning else { return }
        isCheckingDevice = true
        status = "Checking USB connection…"
        let directory = scriptDirectory
        Task.detached {
            let result = Self.runScanner(["--device"], in: directory)
            await MainActor.run {
                self.isCheckingDevice = false
                switch result {
                case .success(let data):
                    if let info = try? JSONDecoder().decode(DeviceInfo.self, from: data), info.connected {
                        self.device = info
                        self.status = "Connected to \(info.name ?? "iPhone")."
                    } else {
                        self.device = nil
                        self.status = "No trusted iPhone found. Connect, unlock and tap Trust."
                    }
                case .failure(let error):
                    self.device = nil
                    self.status = "Device check failed."
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func scanWallet() {
        guard isConnected, !isScanning else { return }
        isScanning = true
        status = "Reading Wallet metadata. Do not disconnect the iPhone…"
        errorMessage = nil
        let directory = scriptDirectory
        Task.detached {
            let result = Self.runScanner(["--scan"], in: directory, timeout: 900)
            await MainActor.run {
                self.isScanning = false
                switch result {
                case .success(let data):
                    guard let response = try? JSONDecoder().decode(ScanResponse.self, from: data) else {
                        self.status = "Wallet scan failed."
                        self.errorMessage = "The scanner returned an invalid response."
                        return
                    }
                    guard response.ok, let found = response.cards, !found.isEmpty else {
                        self.status = "No card hashes were found."
                        self.errorMessage = response.error ?? "No Wallet cards were returned."
                        return
                    }
                    let aliases = Dictionary(uniqueKeysWithValues: self.cards.compactMap { card in
                        card.customName.map { (card.hash, $0) }
                    })
                    self.cards = found.map { card in
                        var merged = card
                        merged.customName = aliases[card.hash]
                        return merged
                    }
                    self.saveCards()
                    self.status = "Found \(found.count) cards. Save the hashes now."
                case .failure(let error):
                    self.status = "Wallet scan failed."
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func copyAll() {
        copy(cards.map { "\($0.displayName)\t\($0.hash)" }.joined(separator: "\n"))
        status = "All card hashes copied."
    }

    func renameCard(hash: String, name: String) {
        guard let index = cards.firstIndex(where: { $0.hash == hash }) else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanned = cards[index].name?.trimmingCharacters(in: .whitespacesAndNewlines)
        cards[index].customName = cleaned.isEmpty || cleaned == scanned ? nil : cleaned
        saveCards()
    }

    @discardableResult
    func importHashes(_ text: String) -> Int {
        let pattern = #"[A-Za-z0-9+_-]{27}="#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return 0 }
        var imported = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = expression.matches(in: line, range: range)
            for match in matches {
                guard let swiftRange = Range(match.range, in: line) else { continue }
                let hash = String(line[swiftRange])
                var importedName: String?
                if matches.count == 1 {
                    let remainder = line.replacingCharacters(in: swiftRange, with: "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t,;|:-"))
                    importedName = remainder.isEmpty ? nil : remainder
                }

                if let index = cards.firstIndex(where: { $0.hash == hash }) {
                    if let importedName { cards[index].customName = importedName }
                } else {
                    cards.append(WalletCard(hash: hash, name: nil, customName: importedName))
                    imported += 1
                }
            }
        }

        if imported > 0 || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saveCards()
            status = "Imported \(imported) new card hashes."
        }
        return imported
    }

    func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AirCard-Wallet-Hashes.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let exported = cards.map { ExportedCard(hash: $0.hash, name: $0.displayName) }
            try encoder.encode(exported).write(to: url, options: .atomic)
            status = "Exported \(cards.count) card hashes."
        } catch { errorMessage = error.localizedDescription }
    }

    func clearResults() {
        cards.removeAll()
        UserDefaults.standard.removeObject(forKey: savedCardsKey)
        status = "Saved results cleared."
    }

    private func saveCards() {
        if let data = try? JSONEncoder().encode(cards) {
            UserDefaults.standard.set(data, forKey: savedCardsKey)
        }
    }

    private func loadCards() {
        guard let data = UserDefaults.standard.data(forKey: savedCardsKey),
              let saved = try? JSONDecoder().decode([WalletCard].self, from: data) else { return }
        cards = saved
    }

    nonisolated private static func runScanner(
        _ arguments: [String], in directory: URL, timeout: TimeInterval = 60
    ) -> Result<Data, Error> {
        let process = Process()
        process.currentDirectoryURL = directory
        let bundledScanner = directory.appendingPathComponent("bin/wallet_scanner")
        if FileManager.default.isExecutableFile(atPath: bundledScanner.path) {
            process.executableURL = bundledScanner
            process.arguments = arguments
        } else {
            let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return .failure(NSError(domain: "AirCardHashScanner", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The bundled scanner is missing and Python 3 was not found."]))
            }
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["wallet_scanner.py"] + arguments
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [directory.appendingPathComponent("bin").path,
                               "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return .failure(error) }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning {
            process.terminate()
            return .failure(NSError(domain: "AirCardHashScanner", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The operation timed out. Reconnect the iPhone and try again."]))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0, !data.isEmpty { return .success(data) }
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(NSError(domain: "AirCardHashScanner", code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : "The scanner exited unexpectedly."]))
    }
}

struct ContentView: View {
    @StateObject private var model = AppViewModel()
    @AppStorage("aircard.hash-scanner.language") private var languageRaw = AppLanguage.english.rawValue
    @State private var showScanConfirmation = false
    @State private var showImportSheet = false

    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .english }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    intro
                    connectionCard
                    scanCard
                    if !model.cards.isEmpty { resultsCard }
                    recoveryCard
                }
                .padding(24)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(tr(language, "Read Wallet now?", "现在读取 Wallet？"), isPresented: $showScanConfirmation) {
            Button(tr(language, "Cancel", "取消"), role: .cancel) {}
            Button(tr(language, "Read Wallet", "读取 Wallet"), role: .destructive) { model.scanWallet() }
        } message: {
            Text(tr(language,
                    "This operation temporarily moves protected Wallet metadata while reading it. Cards may disappear until the iPhone is restarted. Do not disconnect the cable.",
                    "读取过程中会暂时移动受保护的 Wallet 元数据。卡片可能暂时消失，直到重启 iPhone。操作时不要断开数据线。"))
        }
        .alert(tr(language, "Error", "错误"), isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $showImportSheet) {
            ImportHashesSheet(language: language) { text in
                model.importHashes(text)
                showImportSheet = false
            } onCancel: {
                showImportSheet = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "wallet.bifold.fill").font(.system(size: 28)).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("AirCard Hash Scanner").font(.title2.bold())
                Text(tr(language, "Direct Wallet metadata reader for macOS", "macOS Wallet 元数据直接读取工具"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $languageRaw) {
                Text("English").tag(AppLanguage.english.rawValue)
                Text("中文").tag(AppLanguage.chinese.rawValue)
            }
            .pickerStyle(.segmented).frame(width: 150)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr(language, "Get every Wallet card hash in one scan", "一次扫描获取全部 Wallet 卡片 Hash"))
                .font(.largeTitle.bold())
            Text(tr(language,
                    "No phone app, developer mode, LocalDevVPN or card-by-card interaction. Connect a trusted iPhone by USB and save the results for the desktop tool.",
                    "不需要手机 App、开发者模式、LocalDevVPN，也不需要逐张操作卡片。通过 USB 连接已信任的 iPhone，并保存结果供电脑端工具使用。"))
                .font(.title3).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionCard: some View {
        section(title: tr(language, "1. Connect iPhone", "1. 连接 iPhone"), icon: "cable.connector") {
            HStack(spacing: 14) {
                Circle().fill(model.isConnected ? Color.green : Color.orange).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isConnected
                         ? "\(model.device?.name ?? "iPhone") · iOS \(model.device?.version ?? "")"
                         : tr(language, "Waiting for a trusted USB device", "等待已信任的 USB 设备"))
                        .font(.headline)
                    Text(tr(language, "Unlock the iPhone and tap Trust This Computer if prompted.",
                            "请解锁 iPhone；若出现提示，请点击“信任此电脑”。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refreshDevice() } label: {
                    if model.isCheckingDevice { ProgressView().controlSize(.small) }
                    else { Label(tr(language, "Refresh", "刷新"), systemImage: "arrow.clockwise") }
                }
                .disabled(model.isCheckingDevice || model.isScanning)
            }
        }
    }

    private var scanCard: some View {
        section(title: tr(language, "2. Read Wallet", "2. 读取 Wallet"), icon: "externaldrive.badge.magnifyingglass") {
            VStack(alignment: .leading, spacing: 14) {
                Label(tr(language,
                         "Reads the Wallet database directly—no device logs or card-by-card detection.",
                         "直接读取 Wallet 数据库，不使用设备日志，也不需要逐张识别卡片。"),
                      systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { showScanConfirmation = true } label: {
                        HStack {
                            if model.isScanning { ProgressView().controlSize(.small) }
                            Image(systemName: "wallet.pass.fill")
                            Text(model.isScanning ? tr(language, "Reading…", "正在读取…")
                                 : tr(language, "Read all card hashes", "读取全部卡片 Hash"))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!model.isConnected || model.isScanning)

                    Button {
                        showImportSheet = true
                    } label: {
                        Label(tr(language, "Import hashes", "批量导入 Hash"), systemImage: "square.and.arrow.down")
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(model.isScanning)
                }
                Text(model.status).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var resultsCard: some View {
        section(title: tr(language, "3. Save hashes", "3. 保存 Hash"), icon: "square.and.arrow.down") {
            VStack(spacing: 12) {
                HStack {
                    Text(tr(language, "\(model.cards.count) cards found", "找到 \(model.cards.count) 张卡片")).font(.headline)
                    Spacer()
                    Button(tr(language, "Copy all", "复制全部")) { model.copyAll() }
                    Button(tr(language, "Export JSON", "导出 JSON")) { model.exportJSON() }
                    Button(tr(language, "Clear", "清除"), role: .destructive) { model.clearResults() }
                }
                Divider()
                LazyVStack(spacing: 8) {
                    ForEach(model.cards) { card in
                        EditableCardRow(
                            language: language,
                            card: card,
                            onRename: { model.renameCard(hash: card.hash, name: $0) },
                            onResetName: { model.renameCard(hash: card.hash, name: "") },
                            onCopy: { model.copy(card.hash) }
                        )
                    }
                }
            }
        }
    }

    private var recoveryCard: some View {
        section(title: tr(language, "Important recovery information", "重要恢复说明"), icon: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: 9) {
                Text(tr(language,
                        "Reading protected Wallet metadata may temporarily remove cards from Wallet. Save the hashes immediately and use them only with the desktop tool.",
                        "读取受保护的 Wallet 元数据可能会让卡片暂时从 Wallet 消失。请立即保存 Hash，并且只在电脑端工具中使用。"))
                    .font(.headline)
                Text(tr(language,
                        "Restart the iPhone and wait several minutes. If cards do not return, open Settings › Wallet & Apple Pay › AutoFill Cards, select any existing card and try to add it. After iOS says the card already exists, reopen Wallet.",
                        "请重启 iPhone 并等待几分钟。若卡片没有恢复，请打开“设置 › 钱包与 Apple Pay › 自动填充卡片”，选择任意原有卡片并尝试添加。系统提示卡片已存在后，重新打开 Wallet。"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(title: String, icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon).font(.title3.bold())
            content()
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.16)))
    }
}

private struct EditableCardRow: View {
    let language: AppLanguage
    let card: WalletCard
    let onRename: (String) -> Void
    let onResetName: () -> Void
    let onCopy: () -> Void
    @State private var draftName: String

    init(
        language: AppLanguage,
        card: WalletCard,
        onRename: @escaping (String) -> Void,
        onResetName: @escaping () -> Void,
        onCopy: @escaping () -> Void
    ) {
        self.language = language
        self.card = card
        self.onRename = onRename
        self.onResetName = onResetName
        self.onCopy = onCopy
        _draftName = State(initialValue: card.displayName)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "creditcard.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                TextField(tr(language, "Card name", "卡片名称"), text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.headline)
                    .onChange(of: draftName) { _, value in onRename(value) }
                Text(card.hash)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer()
            if card.customName != nil {
                Button {
                    draftName = card.name ?? tr(language, "Unnamed card", "未命名卡片")
                    onResetName()
                } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help(tr(language, "Restore scanned name", "恢复扫描名称"))
            }
            Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help(tr(language, "Copy hash", "复制 Hash"))
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ImportHashesSheet: View {
    let language: AppLanguage
    let onImport: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr(language, "Import card hashes", "批量导入卡片 Hash"))
                    .font(.title2.bold())
                Text(tr(language,
                        "Paste one hash per line, multiple hashes on a line, or a name and hash together. Existing cards are kept and duplicate hashes are merged.",
                        "可每行粘贴一个 Hash、同一行粘贴多个 Hash，或同时粘贴名称和 Hash。已有卡片会保留，重复 Hash 会自动合并。"))
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))

            VStack(alignment: .leading, spacing: 3) {
                Text(tr(language, "Accepted examples", "支持的格式示例")).font(.caption.bold())
                Text("AAAAAAAAAAAAAAAAAAAAAAAAAAA=")
                Text("Transit Card, AAAAAAAAAAAAAAAAAAAAAAAAAAA=")
                Text("Bank Card\tBBBBBBBBBBBBBBBBBBBBBBBBBBB=")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(tr(language, "Cancel", "取消"), action: onCancel)
                Button(tr(language, "Import", "导入")) { onImport(text) }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 620, height: 440)
    }
}

@main
struct AirCardHashScannerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }.windowResizability(.contentMinSize)
    }
}

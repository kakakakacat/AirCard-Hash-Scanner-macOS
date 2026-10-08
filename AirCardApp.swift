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
    var name: String?
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

private struct OperationResponse: Decodable {
    let ok: Bool
    let error: String?
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var device: DeviceInfo?
    @Published var cards: [WalletCard] = []
    @Published var status = "Connect an unlocked iPhone by USB."
    @Published var isCheckingDevice = false
    @Published var isScanning = false
    @Published var scanProgress = 0.0
    @Published var isFlashing = false
    @Published var flashProgress = 0.0
    @Published var flashPhase = 0.0
    @Published var flashCurrentCardName = ""
    @Published var artwork: [String: URL] = [:]
    @Published var errorMessage: String?
    @Published var showPostScanReminder = false
    @Published var showWriteCompleteReminder = false

    private let scriptDirectory: URL
    private let savedCardsKey = "aircard.hash-scanner.cards"
    private let savedArtworkKey = "aircard.wallet-tool.artwork"
    private var scanProcess: Process?
    private var scanIDs = Set<String>()
    private var pendingActivationIDs = Set<String>()
    private var walletCatalog = WalletCatalog.empty
    private var catalogRefreshTask: Task<Void, Never>?
    private var flashProgressTask: Task<Void, Never>?
    private var flashCompletedCount = 0
    private var flashTotalCount = 1

    init() {
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("wallet_scanner.py").path) {
            scriptDirectory = resources
        } else {
            scriptDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        loadCards()
        loadArtwork()
        refreshDevice()
    }

    var isConnected: Bool { device?.connected == true && device?.udid != nil }

    func refreshDevice() {
        guard !isCheckingDevice, !isScanning, !isFlashing else { return }
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
        guard isConnected, !isScanning, !isFlashing,
              let udid = device?.udid else { return }
        let helper = scriptDirectory.appendingPathComponent("bin/device_helper")
        let developmentHelper = scriptDirectory.appendingPathComponent("build/device_helper")
        let executable = FileManager.default.isExecutableFile(atPath: helper.path)
            ? helper : developmentHelper
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            errorMessage = "The bundled device log helper is missing. Reinstall or rebuild the app."
            return
        }

        isScanning = true
        scanProgress = 0.08
        scanIDs = []
        pendingActivationIDs = []
        status = "Connecting to the read-only Wallet log stream…"
        errorMessage = nil

        refreshWalletCatalog()
        let pipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["syslog", udid]
        process.standardOutput = pipe
        process.standardError = pipe
        scanProcess = process

        do {
            try process.run()
            scanProgress = 0.18
        } catch {
            scanProcess = nil
            isScanning = false
            status = "Could not start Wallet log scanning."
            errorMessage = error.localizedDescription
            return
        }

        Task.detached {
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            do {
                while true {
                    let chunk = try handle.read(upToCount: 65_536) ?? Data()
                    if chunk.isEmpty {
                        if buffer.isEmpty { break }
                        buffer.append(0x0A)
                    } else {
                        buffer.append(chunk)
                    }

                    while let newline = buffer.range(of: Data([0x0A])) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newline.lowerBound)
                        buffer.removeSubrange(buffer.startIndex..<newline.upperBound)
                        guard let line = String(data: lineData, encoding: .utf8) else { continue }
                        await self.processWalletLogLine(line, process: process)
                    }
                    if chunk.isEmpty { break }
                }
                process.waitUntilExit()
                await MainActor.run {
                    guard self.scanProcess === process else { return }
                    self.scanProcess = nil
                    self.isScanning = false
                    self.scanProgress = self.scanIDs.isEmpty ? 0 : 1
                    self.status = self.scanIDs.isEmpty
                        ? "The log stream ended before any card hashes were detected."
                        : "Found and saved \(self.scanIDs.count) card hash(es)."
                    self.showPostScanReminder = !self.scanIDs.isEmpty
                }
            } catch {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                await MainActor.run {
                    guard self.scanProcess === process else { return }
                    self.scanProcess = nil
                    self.isScanning = false
                    self.status = "Wallet log scanning stopped unexpectedly."
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func stopWalletScan() {
        guard isScanning else { return }
        let process = scanProcess
        scanProcess = nil
        if let process, process.isRunning { process.terminate() }
        isScanning = false
        scanProgress = scanIDs.isEmpty ? 0 : 1
        saveCards()
        if scanIDs.isEmpty {
            status = "No hashes detected. Open Wallet once, then scan again."
        } else {
            status = "Found and saved \(scanIDs.count) card hash(es)."
            showPostScanReminder = true
        }
    }

    private func processWalletLogLine(_ line: String, process: Process) {
        guard scanProcess === process else { return }
        if line.hasPrefix("AirCard scanner: ") {
            if line.contains("Connected to the unified") {
                scanProgress = max(scanProgress, 0.28)
                status = "Scanner connected. Open Wallet briefly to expose the card list."
            }
            return
        }

        let lower = line.lowercased()
        let isWalletSubsystem = lower.contains("passd") ||
            lower.contains("passbook") || lower.contains("passkit") ||
            lower.contains("nfcd") || lower.contains("stockholm") ||
            lower.contains("nanopassd") || lower.contains("wallet") ||
            lower.contains("pdcardfilemanager") || lower.contains("pdpasslibrary") ||
            lower.contains("verificationcheck") || lower.contains("/cards/")
        guard isWalletSubsystem else { return }

        let isWalletContext = lower.contains("card") || lower.contains("pass") ||
            lower.contains("payment") || lower.contains("pkpass") ||
            lower.contains("uniqueid") || lower.contains("identifier") ||
            lower.contains("face") || lower.contains("cache") ||
            lower.contains("stockholm") || lower.contains("verificationcheck") ||
            lower.contains("/cards/")
        guard isWalletContext else { return }

        for activationID in WalletScanParser.activationIDs(in: line) {
            if let card = walletCatalog.payment(forActivationID: activationID) {
                recordDetectedCard(card.id, name: card.name)
            } else {
                pendingActivationIDs.insert(activationID)
            }
        }

        var candidates = WalletScanParser.cardIDs(in: line)
        if candidates.isEmpty { candidates = WalletScanParser.fallbackCardIDs(in: line) }
        for id in candidates { recordDetectedCard(id, name: walletCatalog.name(for: id)) }
    }

    private func recordDetectedCard(_ id: String, name: String?) {
        guard !WalletScanParser.placeholders.contains(id) else { return }
        let isNewThisScan = scanIDs.insert(id).inserted
        if let index = cards.firstIndex(where: { $0.hash == id }) {
            if let name, !name.isEmpty { cards[index].name = name }
        } else {
            cards.append(WalletCard(hash: id, name: name, customName: nil))
        }
        guard isNewThisScan else { return }
        saveCards()
        if name == nil && walletCatalog.name(for: id) == nil {
            catalogRefreshTask?.cancel()
            catalogRefreshTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                self.refreshWalletCatalog()
            }
        }
        let scaled = 0.34 + min(0.58, log2(Double(scanIDs.count) + 1) * 0.12)
        scanProgress = max(scanProgress, scaled)
        status = "Detected \(scanIDs.count) card hash(es). Keep Wallet open briefly, then finish scanning."
    }

    private func refreshWalletCatalog() {
        guard let product = device?.product else { return }
        let directory = scriptDirectory
        let confirmedIDs = cards.map(\.hash)
        Task.detached {
            let result = Self.readLocalWalletCatalog(
                product: product,
                confirmedIDs: confirmedIDs,
                in: directory
            )
            await MainActor.run {
                guard case .success(let catalog) = result else { return }
                self.walletCatalog = catalog
                for index in self.cards.indices {
                    if let name = catalog.name(for: self.cards[index].hash) {
                        self.cards[index].name = name
                    }
                }
                for activationID in self.pendingActivationIDs {
                    if let card = catalog.payment(forActivationID: activationID) {
                        self.recordDetectedCard(card.id, name: card.name)
                    }
                }
                self.pendingActivationIDs = self.pendingActivationIDs.filter {
                    catalog.payment(forActivationID: $0) == nil
                }
                self.saveCards()
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
        artwork.removeAll()
        UserDefaults.standard.removeObject(forKey: savedCardsKey)
        UserDefaults.standard.removeObject(forKey: savedArtworkKey)
        status = "Saved results cleared."
    }

    func chooseArtwork(for hashes: [String]) {
        guard !hashes.isEmpty, !isFlashing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose artwork for the selected Wallet card(s)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setArtwork(url, for: hashes)
    }

    @discardableResult
    func setArtwork(_ url: URL, for hashes: [String]) -> Bool {
        guard !hashes.isEmpty,
              url.isFileURL,
              UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else {
            errorMessage = "Drop a supported image file onto the card."
            return false
        }
        for hash in hashes { artwork[hash] = url }
        saveArtwork()
        status = "Artwork selected for \(hashes.count) card(s). Preview it before applying."
        return true
    }

    func clearArtwork(for hash: String) {
        artwork.removeValue(forKey: hash)
        saveArtwork()
    }

    func applyCovers(hashes: [String]? = nil) {
        guard isConnected, !isFlashing, !isScanning else { return }
        let requested = Set(hashes ?? Array(artwork.keys))
        let jobs = cards.compactMap { card -> (String, URL)? in
            guard requested.contains(card.hash), let url = artwork[card.hash] else { return nil }
            return (card.hash, url)
        }
        guard !jobs.isEmpty else {
            errorMessage = "Choose artwork for at least one card first."
            return
        }

        isFlashing = true
        flashProgress = 0
        flashPhase = 0
        flashCompletedCount = 0
        flashTotalCount = jobs.count
        flashCurrentCardName = cards.first(where: { $0.hash == jobs[0].0 })?.displayName ?? jobs[0].0
        status = "Applying Wallet covers…"
        errorMessage = nil
        let directory = scriptDirectory
        let progressFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("aircard-write-\(UUID().uuidString).progress")
        try? "0.0".write(to: progressFile, atomically: true, encoding: .utf8)
        beginFlashProgress(from: progressFile)

        Task.detached {
            var failures: [String] = []
            for (index, job) in jobs.enumerated() {
                try? "0.0".write(to: progressFile, atomically: true, encoding: .utf8)
                await MainActor.run {
                    self.flashCompletedCount = index
                    self.flashPhase = 0
                    self.flashCurrentCardName = self.cards.first(where: { $0.hash == job.0 })?.displayName
                        ?? job.0
                }
                let result = Self.runScanner(
                    ["--flash", job.0, job.1.path, "--progress-file", progressFile.path],
                    in: directory,
                    timeout: 900
                )
                switch result {
                case .success(let data):
                    let response = try? JSONDecoder().decode(OperationResponse.self, from: data)
                    if response?.ok != true {
                        failures.append(response?.error ?? String(job.0.prefix(10)))
                    }
                case .failure(let error):
                    failures.append(error.localizedDescription)
                }
                await MainActor.run {
                    self.flashCompletedCount = index + 1
                    self.flashPhase = 1
                    self.flashProgress = Double(index + 1) / Double(jobs.count)
                    self.status = "Applied \(index + 1) of \(jobs.count) cover(s)…"
                }
            }
            let failureMessages = failures
            await MainActor.run {
                self.flashProgressTask?.cancel()
                self.flashProgressTask = nil
                try? FileManager.default.removeItem(at: progressFile)
                self.isFlashing = false
                if failureMessages.isEmpty {
                    self.status = "All selected covers were applied. Reopen Wallet to refresh."
                    self.showWriteCompleteReminder = true
                } else {
                    self.status = "One or more covers could not be applied."
                    self.errorMessage = failureMessages.joined(separator: "\n")
                }
            }
        }
    }

    private func beginFlashProgress(from progressFile: URL) {
        flashProgressTask?.cancel()
        flashProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard let self, self.isFlashing else { return }
                guard let text = try? String(contentsOf: progressFile, encoding: .utf8),
                      let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    continue
                }
                self.flashPhase = min(1, max(0, value))
                self.flashProgress = min(
                    0.99,
                    (Double(self.flashCompletedCount) + self.flashPhase)
                        / Double(max(1, self.flashTotalCount))
                )
            }
        }
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

    private func saveArtwork() {
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: artwork.map { ($0.key, $0.value.path) }),
            forKey: savedArtworkKey
        )
    }

    private func loadArtwork() {
        guard let stored = UserDefaults.standard.dictionary(forKey: savedArtworkKey) as? [String: String] else { return }
        artwork = stored.reduce(into: [:]) { result, entry in
            if FileManager.default.fileExists(atPath: entry.value) {
                result[entry.key] = URL(fileURLWithPath: entry.value)
            }
        }
    }

    nonisolated private static func readLocalWalletCatalog(
        product: String, confirmedIDs: [String], in directory: URL
    ) -> Result<WalletCatalog, Error> {
        let script = directory.appendingPathComponent("wallet_catalog.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return .success(.empty)
        }
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .success(.empty)
        }
        do {
            let request = try JSONSerialization.data(withJSONObject: [
                "product": product,
                "confirmedIDs": confirmedIDs,
            ])
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script.path]
            process.currentDirectoryURL = directory
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            input.fileHandleForWriting.write(request)
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                throw NSError(domain: "AirCardWalletCatalog", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: detail ?? "Local Wallet cache lookup failed."])
            }
            return .success(try JSONDecoder().decode(WalletCatalog.self, from: data))
        } catch {
            return .failure(error)
        }
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
    @State private var showWriteConfirmation = false
    @State private var pendingWriteHashes: [String] = []

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
                    safetyCard
                }
                .padding(24)
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(tr(language, "Start read-only Wallet scan?", "开始只读 Wallet 扫描？"), isPresented: $showScanConfirmation) {
            Button(tr(language, "Cancel", "取消"), role: .cancel) {}
            Button(tr(language, "Start scanning", "开始扫描")) { model.scanWallet() }
        } message: {
            Text(tr(language,
                    "Scanning only listens to Wallet-related system logs. It does not move Wallet files or change card covers. Keep the iPhone connected and open Wallet briefly after scanning starts.",
                    "扫描只监听 Wallet 相关系统日志，不会移动 Wallet 文件，也不会修改卡片封面。开始后请保持 iPhone 连接，并短暂打开一次 Wallet。"))
        }
        .alert(tr(language, "Wallet scan complete", "Wallet 扫描完成"),
               isPresented: $model.showPostScanReminder) {
            Button(tr(language, "Done", "完成"), role: .cancel) {}
        } message: {
            Text(tr(language,
                    "The detected hashes and card names were saved automatically. This read-only scan did not move protected Wallet files or invalidate existing covers.",
                    "检测到的 Hash 和卡片名称已自动保存。本次只读扫描没有移动受保护的 Wallet 文件，也不会使原有封面失效。"))
        }
        .alert(tr(language, "Apply selected cover?", "确认写入所选封面？"),
               isPresented: $showWriteConfirmation) {
            Button(tr(language, "Cancel", "取消"), role: .cancel) { pendingWriteHashes.removeAll() }
            Button(tr(language, "Confirm and apply", "确认并写入"), role: .destructive) {
                let hashes = pendingWriteHashes
                pendingWriteHashes.removeAll()
                model.applyCovers(hashes: hashes)
            }
        } message: {
            Text(tr(language,
                    "The preview will be written to \(pendingWriteHashes.count) card(s). This modifies Wallet artwork and clears only the corresponding rendered-cover caches.",
                    "即将把预览封面写入 \(pendingWriteHashes.count) 张卡片。此操作会修改 Wallet 素材，并仅清理对应卡片的封面渲染缓存。"))
        }
        .alert(tr(language, "Cover update complete", "封面写入完成"),
               isPresented: $model.showWriteCompleteReminder) {
            Button(tr(language, "Got it", "知道了"), role: .cancel) {}
        } message: {
            Text(tr(language,
                    "The selected covers were written successfully. On the iPhone, completely close the Wallet app and open it again to refresh the card covers.",
                    "所选封面已写入成功。请在 iPhone 上完全关闭 Wallet 应用，然后重新打开 Wallet，以刷新并显示新的卡片封面。"))
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
                Text("AirCard Wallet Tool").font(.title2.bold())
                Text(tr(language, "Wallet hash reader and cover editor for macOS", "macOS Wallet Hash 读取与封面修改工具"))
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
            Text(tr(language, "Read Wallet hashes and customize card covers", "读取 Wallet Hash 并修改卡片封面"))
                .font(.largeTitle.bold())
            Text(tr(language,
                    "Connect a trusted iPhone by USB, discover card hashes from Wallet's read-only system log, organize names, then apply custom covers with the original Mac AirTraffic workflow.",
                    "通过 USB 连接已信任的 iPhone，从 Wallet 的只读系统日志发现卡片 Hash、整理名称，再使用原版 Mac AirTraffic 流程写入自定义封面。"))
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
                         "Read-only log scanning: no Wallet database access, file moves, or cover invalidation.",
                         "只读日志扫描：不访问 Wallet 数据库、不移动文件，也不会让原有封面失效。"),
                      systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        if model.isScanning { model.stopWalletScan() }
                        else { showScanConfirmation = true }
                    } label: {
                        HStack {
                            if model.isScanning { ProgressView().controlSize(.small) }
                            Image(systemName: "wallet.pass.fill")
                            Text(model.isScanning ? tr(language, "Finish scan", "完成扫描")
                                 : tr(language, "Read all card hashes", "读取全部卡片 Hash"))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .tint(model.isScanning ? .red : .blue)
                    .disabled(!model.isConnected || model.isFlashing)

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
                if model.isScanning {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(scanProgressLabel).font(.caption.bold())
                            Spacer()
                            Text("\(Int(model.scanProgress * 100))%")
                                .font(.system(.caption, design: .monospaced))
                        }
                        ProgressView(value: model.scanProgress, total: 1)
                            .progressViewStyle(.linear)
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private var scanProgressLabel: String {
        if model.scanProgress < 0.22 {
            return tr(language, "Connecting to iPhone logs…", "正在连接 iPhone 日志…")
        }
        if model.scanProgress < 0.34 {
            return tr(language, "Log scanner ready—open Wallet once…", "日志扫描器已就绪，请打开一次 Wallet…")
        }
        return tr(language, "Discovering card hashes from Wallet activity…", "正在从 Wallet 活动中发现卡片 Hash…")
    }

    private var resultsCard: some View {
        section(title: tr(language, "3. Manage cards and covers", "3. 管理卡片与封面"), icon: "photo.on.rectangle.angled") {
            VStack(spacing: 12) {
                HStack {
                    Text(tr(language, "\(model.cards.count) cards found", "找到 \(model.cards.count) 张卡片")).font(.headline)
                    Spacer()
                    Button(tr(language, "Copy all", "复制全部")) { model.copyAll() }
                    Button(tr(language, "Export JSON", "导出 JSON")) { model.exportJSON() }
                    Button(tr(language, "Clear", "清除"), role: .destructive) { model.clearResults() }
                }
                HStack {
                    Button {
                        model.chooseArtwork(for: model.cards.map(\.hash))
                    } label: {
                        Label(tr(language, "Choose cover for all", "为全部卡片选择封面"), systemImage: "photo.badge.plus")
                    }
                    Button {
                        requestCoverWrite(model.cards.map(\.hash))
                    } label: {
                        Label(tr(language, "Review and apply covers", "预览并确认写入"), systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isConnected || model.isFlashing || model.artwork.isEmpty)
                    Spacer()
                }
                if model.isFlashing {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text(flashProgressLabel).font(.caption.bold())
                            Text(model.flashCurrentCardName)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text("\(Int(model.flashProgress * 100))%")
                                .font(.system(.caption, design: .monospaced))
                        }
                        ProgressView(value: model.flashProgress, total: 1)
                            .progressViewStyle(.linear)
                    }
                    .padding(12)
                    .background(Color.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                }
                Divider()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                    ForEach(model.cards) { card in
                        EditableCardTile(
                            language: language,
                            card: card,
                            artworkURL: model.artwork[card.hash],
                            isFlashing: model.isFlashing,
                            onRename: { model.renameCard(hash: card.hash, name: $0) },
                            onResetName: { model.renameCard(hash: card.hash, name: "") },
                            onCopy: { model.copy(card.hash) },
                            onChooseArtwork: { model.chooseArtwork(for: [card.hash]) },
                            onDropArtwork: { model.setArtwork($0, for: [card.hash]) },
                            onClearArtwork: { model.clearArtwork(for: card.hash) },
                            onApplyArtwork: { requestCoverWrite([card.hash]) }
                        )
                    }
                }
            }
        }
    }

    private var flashProgressLabel: String {
        if model.flashPhase < 0.24 {
            return tr(language, "Preparing artwork…", "正在处理封面图片…")
        }
        if model.flashPhase < 0.74 {
            return tr(language, "Writing Wallet assets…", "正在写入 Wallet 素材…")
        }
        return tr(language, "Refreshing Wallet caches…", "正在刷新 Wallet 缓存…")
    }

    private func requestCoverWrite(_ hashes: [String]) {
        let selected = hashes.filter { model.artwork[$0] != nil }
        guard !selected.isEmpty else {
            model.errorMessage = tr(language,
                                    "Choose or drop artwork onto at least one card first.",
                                    "请先为至少一张卡片选择或拖入封面图片。")
            return
        }
        pendingWriteHashes = selected
        showWriteConfirmation = true
    }

    private var safetyCard: some View {
        section(title: tr(language, "Safe scanning and cover writing", "安全扫描与封面写入"), icon: "checkmark.shield.fill") {
            VStack(alignment: .leading, spacing: 9) {
                Text(tr(language,
                        "Hash scanning is read-only and does not touch protected Wallet files.",
                        "Hash 扫描是只读操作，不会触碰受保护的 Wallet 文件。"))
                    .font(.headline)
                Text(tr(language,
                        "Applying a cover is a separate write operation. After it finishes, completely close and reopen Wallet to refresh the rendered cover. A phone restart is not required for scanning.",
                        "写入封面是独立的修改操作。完成后请彻底关闭并重新打开 Wallet，以刷新渲染封面；扫描本身不需要重启手机。"))
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

private struct EditableCardTile: View {
    let language: AppLanguage
    let card: WalletCard
    let artworkURL: URL?
    let isFlashing: Bool
    let onRename: (String) -> Void
    let onResetName: () -> Void
    let onCopy: () -> Void
    let onChooseArtwork: () -> Void
    let onDropArtwork: (URL) -> Bool
    let onClearArtwork: () -> Void
    let onApplyArtwork: () -> Void
    @State private var draftName: String
    @State private var isDropTarget = false

    init(
        language: AppLanguage,
        card: WalletCard,
        artworkURL: URL?,
        isFlashing: Bool,
        onRename: @escaping (String) -> Void,
        onResetName: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onChooseArtwork: @escaping () -> Void,
        onDropArtwork: @escaping (URL) -> Bool,
        onClearArtwork: @escaping () -> Void,
        onApplyArtwork: @escaping () -> Void
    ) {
        self.language = language
        self.card = card
        self.artworkURL = artworkURL
        self.isFlashing = isFlashing
        self.onRename = onRename
        self.onResetName = onResetName
        self.onCopy = onCopy
        self.onChooseArtwork = onChooseArtwork
        self.onDropArtwork = onDropArtwork
        self.onClearArtwork = onClearArtwork
        self.onApplyArtwork = onApplyArtwork
        _draftName = State(initialValue: card.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.secondary.opacity(0.08))
                if let artworkURL, let image = NSImage(contentsOf: artworkURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(.blue)
                        Text(tr(language, "Drop an image here", "拖拽图片到这里"))
                            .font(.headline)
                        Text(tr(language, "or click Choose cover", "或点击“选择封面”"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.blue.opacity(0.18))
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 38))
                        Text(tr(language, "Release to preview", "松开以预览"))
                            .font(.headline)
                    }
                    .foregroundStyle(.blue)
                }
            }
            .aspectRatio(1536.0 / 969.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(isDropTarget ? Color.blue : Color.secondary.opacity(0.18),
                        lineWidth: isDropTarget ? 3 : 1))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return onDropArtwork(url)
            } isTargeted: { isDropTarget = $0 }

            VStack(alignment: .leading, spacing: 6) {
                TextField(tr(language, "Card name", "卡片名称"), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.bold())
                    .onChange(of: draftName) { _, value in onRename(value) }
                HStack(spacing: 6) {
                    Text(card.hash)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help(tr(language, "Copy hash", "复制 Hash"))
                }
            }

            HStack(spacing: 8) {
                if card.customName != nil {
                    Button {
                        draftName = card.name ?? tr(language, "Unnamed card", "未命名卡片")
                        onResetName()
                    } label: { Image(systemName: "arrow.uturn.backward") }
                        .help(tr(language, "Restore scanned name", "恢复扫描名称"))
                }
                Button(action: onChooseArtwork) {
                    Label(tr(language, "Choose cover", "选择封面"), systemImage: "photo.badge.plus")
                }
                .disabled(isFlashing)
                if artworkURL != nil {
                    Button(action: onClearArtwork) { Image(systemName: "xmark.circle") }
                        .help(tr(language, "Clear selected cover", "清除已选择封面"))
                        .disabled(isFlashing)
                    Spacer()
                    Button(action: onApplyArtwork) {
                        Label(tr(language, "Confirm write", "确认写入"), systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isFlashing)
                } else {
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.14)))
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

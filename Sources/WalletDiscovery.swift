import Foundation

struct WalletCachedCard: Codable {
    let id: String
    let name: String
    let source: String
    let activationID: String?
}

struct WalletCatalog: Codable {
    var paymentStatus: String
    var payments: [WalletCachedCard]
    var memberships: [WalletCachedCard]
    var warnings: [String]
    var cacheUpdatedAt: String?

    static let empty = WalletCatalog(
        paymentStatus: "unavailable",
        payments: [],
        memberships: [],
        warnings: [],
        cacheUpdatedAt: nil
    )

    func name(for id: String) -> String? {
        (payments + memberships).first(where: { $0.id == id })?.name
    }

    func payment(forActivationID id: String) -> WalletCachedCard? {
        payments.first { $0.activationID?.caseInsensitiveCompare(id) == .orderedSame }
    }
}

// Extract only identifiers emitted in Wallet-related unified-log records. Scanning
// never opens, moves, or rewrites protected Wallet files on the connected iPhone.
enum WalletScanParser {
    static let cardReferences = [
        try! NSRegularExpression(pattern: #"/([-A-Za-z0-9_+=]{20,64})\.(?:pkpass|cache|pkcache)(?=[/\s\"'\),]|$)"#),
        try! NSRegularExpression(pattern: #"/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,64})(?=[/\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"PDCardFileManager:\s*writing card\s+([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"PDPassLibrary:\s*wrote pass\s+([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"VerificationCheck\.([-A-Za-z0-9_+=]{20,64})(?=[\s\"'\),]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"selected pass uniqueID\s*:\s*\"?([-A-Za-z0-9_+=]{20,64})\"?"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"Dashboard loading[^:]*:\s*for\s+([-A-Za-z0-9_+=]{20,80})(?=[,\s\"'\)]|$)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"Dashboard loading[^:]*:\s+([-A-Za-z0-9_+=]{20,80})\s+-"#, options: .caseInsensitive),
    ]

    static let passIDList = try! NSRegularExpression(
        pattern: #"passIDs\[(?:InSession|global)\]\s*:\s*(?:\{\s*)?\(([^)]*)\)"#,
        options: .caseInsensitive
    )
    static let cardID = try! NSRegularExpression(
        pattern: #"(?<![-A-Za-z0-9_+=])[-A-Za-z0-9_+=]{20,64}(?![-A-Za-z0-9_+=])"#
    )
    static let activation = try! NSRegularExpression(
        pattern: #"setActivePaymentApplet.{0,4096}?requestedApplet\s*:.{0,4096}?(?:identifier\s*=\s*|\"identifier\"\s*:\s*\")([A-Fa-f0-9]{10,64})\b"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    static let fallbackToken = try! NSRegularExpression(
        pattern: #"(?<![-A-Za-z0-9+/=])([A-Za-z0-9+/_-]{27}=)(?![-A-Za-z0-9+/=])"#
    )
    static let placeholders: Set<String> = [
        "OM6NYhwXMZrAw0sRUjR62wmF4ZQ=",
        "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
        "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
        "hwAtAmHKYwsQrJbT5cTNDsaxVME=",
    ]

    static func cardIDs(in line: String) -> [String] {
        let lineRange = NSRange(line.startIndex..., in: line)
        var candidates = cardReferences.flatMap { regex in
            regex.matches(in: line, range: lineRange).compactMap { match -> (Int, String)? in
                guard let range = Range(match.range(at: 1), in: line) else { return nil }
                return (match.range.location, String(line[range]))
            }
        }
        for listMatch in passIDList.matches(in: line, range: lineRange) {
            candidates += cardID.matches(in: line, range: listMatch.range(at: 1)).compactMap { match in
                guard let range = Range(match.range, in: line) else { return nil }
                return (match.range.location, String(line[range]))
            }
        }
        candidates.sort { $0.0 < $1.0 }
        var seen = Set<String>()
        return candidates.compactMap { _, id in
            guard !placeholders.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    static func fallbackCardIDs(in line: String) -> [String] {
        let lineRange = NSRange(line.startIndex..., in: line)
        var seen = Set<String>()
        return fallbackToken.matches(in: line, range: lineRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: line) else { return nil }
            let id = String(line[range])
            guard !placeholders.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    static func activationIDs(in line: String) -> [String] {
        activation.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[range]).uppercased()
        }
    }
}

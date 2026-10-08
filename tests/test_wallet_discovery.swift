import Foundation

@main
struct WalletDiscoveryTests {
    static func main() {
        let a = String(repeating: "A", count: 27) + "="
        let b = String(repeating: "B", count: 27) + "="
        let c = String(repeating: "C", count: 27) + "="

        let caches = "Wallet /Cards/\(b).cache/Preview /Cards/\(a).pkpass/en.lproj"
        precondition(WalletScanParser.cardIDs(in: caches) == [b, a])
        precondition(WalletScanParser.cardIDs(in: "passd identifier \(a)").isEmpty)

        let global = "nfcd: passIDs[InSession]: {(\"\(c)\")} passIDs[global]: {(\"\(a)\", \"\(b)\")}"
        precondition(WalletScanParser.cardIDs(in: global) == [c, a, b])

        let dashboard = "Passbook(PassKitUI): Dashboard loading (...): for \(a), pass feature unknown"
        precondition(WalletScanParser.cardIDs(in: dashboard) == [a])
        precondition(WalletScanParser.fallbackCardIDs(in: "passd: Wallet card event \(b)") == [b])

        let activation = "A00000000310100100000020"
        let activationLine = "setActivePaymentApplet: x requestedApplet: {\"identifier\":\"\(activation)\",\"family\":0}"
        precondition(WalletScanParser.activationIDs(in: activationLine) == [activation])

        print("Wallet log discovery parser checks passed")
    }
}

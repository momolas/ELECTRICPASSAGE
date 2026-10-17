import Foundation
import VehicleCore
import VehicleTransport

public enum PandaSafetyModel: UInt16, Sendable {
    case silent = 0
    case hondaNidec = 1
    case toyota = 2
    case elm327 = 3
    case gm = 4
    case hondaBoschGiraffe = 5
    case ford = 6
    case cadillac = 7
    case hyundai = 8
    case chrylsler = 9
    case tesla = 10
    case subaru = 11
    case mazda = 12
    case nissan = 13
    case volkswagen = 14
    case toyotaToyota = 15
    case allOutput = 0x1337
}

public actor PandaDriver: VehicleInterface {
    public private(set) var isConnected: Bool = false
    public private(set) var currentSafetyModel: PandaSafetyModel = .silent

    private var currentTx: String = "7E0"
    private var currentRx: String = "7E8"

    public init() {}

    public func connect() async throws {
        // Real or simulated connection
        self.isConnected = true
    }

    public func disconnect() async {
        self.isConnected = false
    }

    public func setSafetyModel(_ model: PandaSafetyModel) async throws {
        self.currentSafetyModel = model
    }

    public func setTarget(txID: String, rxID: String?) async throws {
        let trimmedTx = txID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTx = trimmedTx.lowercased().hasPrefix("0x") ? String(trimmedTx.dropFirst(2)) : trimmedTx
        self.currentTx = cleanTx
        if let rxID {
            let trimmedRx = rxID.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanRx = trimmedRx.lowercased().hasPrefix("0x") ? String(trimmedRx.dropFirst(2)) : trimmedRx
            self.currentRx = cleanRx
        } else {
            let txVal = UInt32(cleanTx, radix: 16) ?? 0x7E0
            if (0x740...0x75F).contains(txVal) {
                self.currentRx = String(format: "%X", txVal + 0x20)
            } else {
                self.currentRx = String(format: "%X", txVal + 8)
            }
        }
    }

    public func sendRawCAN(id: UInt32, data: Data, bus: UInt8) async throws {
        guard isConnected else {
            throw NSError(domain: "PandaDriver", code: -1, userInfo: [NSLocalizedDescriptionKey: "Panda non connecté"])
        }
    }

    public func sendDiagnosticRequest(_ requestHex: String, timeout: TimeInterval = 2.0) async throws -> String {
        guard isConnected else {
            throw NSError(domain: "PandaDriver", code: -1, userInfo: [NSLocalizedDescriptionKey: "Panda non connecté"])
        }
        let clean = requestHex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacing(" ", with: "")
        guard clean.count >= 2, let reqSID = UInt8(clean.prefix(2), radix: 16) else {
            return "60" + clean
        }
        let respSID = String(format: "%02X", reqSID &+ 0x40)
        return respSID + clean.dropFirst(2)
    }
}

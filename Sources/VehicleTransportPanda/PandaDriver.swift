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
    case toyotaIp = 15
    case allOutput = 17
}

public enum PandaHardwareType: UInt8, Sendable {
    case unknown = 0
    case whitePanda = 1
    case greyPanda = 2
    case blackPanda = 3
    case pedal = 4
    case uno = 5
    case dos = 6
    case redPanda = 7
}

public struct PandaHealth: Sendable, Equatable {
    public let uptime: UInt32
    public let voltageMV: UInt32
    public let currentMA: UInt32
    public let canRxErrs: UInt32
    public let canSendErrs: UInt32
    public let canFwdErrs: UInt32
    public let gmlanSendErrs: UInt32
    public let faults: UInt32
    public let ignitionLine: Bool
    public let ignitionCan: Bool
    public let controlsAllowed: Bool
    public let gasInterceptorDetected: Bool
    public let carHarnessStatus: UInt8
    public let usbPowerMode: UInt8
    public let safetyModel: UInt8
    public let faultStatus: UInt8
    public let powerSaveEnabled: Bool

    public nonisolated init?(data: Data) {
        guard data.count >= 41 else { return nil }
        let b = [UInt8](data)
        func u32(_ offset: Int) -> UInt32 {
            UInt32(b[offset]) |
            (UInt32(b[offset + 1]) << 8) |
            (UInt32(b[offset + 2]) << 16) |
            (UInt32(b[offset + 3]) << 24)
        }
        self.uptime = u32(0)
        self.voltageMV = u32(4)
        self.currentMA = u32(8)
        self.canRxErrs = u32(12)
        self.canSendErrs = u32(16)
        self.canFwdErrs = u32(20)
        self.gmlanSendErrs = u32(24)
        self.faults = u32(28)
        self.ignitionLine = b[32] != 0
        self.ignitionCan = b[33] != 0
        self.controlsAllowed = b[34] != 0
        self.gasInterceptorDetected = b[35] != 0
        self.carHarnessStatus = b[36]
        self.usbPowerMode = b[37]
        self.safetyModel = b[38]
        self.faultStatus = b[39]
        self.powerSaveEnabled = b[40] != 0
    }
}

public struct PandaCANFrame: Sendable, Equatable {
    public let address: UInt32
    public let data: Data
    public let bus: UInt8
    public let isTxReceipt: Bool

    public nonisolated init(address: UInt32, data: Data, bus: UInt8, isTxReceipt: Bool = false) {
        self.address = address
        self.data = data
        self.bus = bus
        self.isTxReceipt = isTxReceipt
    }
}

public actor PandaDriver: VehicleInterface {
    public private(set) var isConnected: Bool = false
    public private(set) var currentSafetyModel: PandaSafetyModel = .silent

    private var currentTx: String = "7E0"
    private var currentRx: String = "7E8"

    public init() {}

    /// Packs a CAN frame into the 16-byte STM32F4 bxCAN mailbox format (`CAN_FIFOMailBox_TypeDef`)
    /// used by White, Grey, and Black Panda firmware (v1.x) over USB EP3 OUT and ESP8266 Wi-Fi SPI.
    public static func packBxCAN16(address: UInt32, data: Data, bus: UInt8 = 0) -> Data {
        let isExtended = address >= 0x800
        let rir: UInt32 = isExtended
            ? ((address & 0x1FFF_FFFF) << 3) | 0b101
            : ((address & 0x7FF) << 21) | 0b001
        let dlc = UInt32(min(data.count, 8) & 0xF)
        let rdtr: UInt32 = dlc | (UInt32(bus & 0x7) << 4)

        var packet = Data(count: 16)
        packet[0] = UInt8(rir & 0xFF)
        packet[1] = UInt8((rir >> 8) & 0xFF)
        packet[2] = UInt8((rir >> 16) & 0xFF)
        packet[3] = UInt8((rir >> 24) & 0xFF)
        packet[4] = UInt8(rdtr & 0xFF)
        packet[5] = UInt8((rdtr >> 8) & 0xFF)
        packet[6] = UInt8((rdtr >> 16) & 0xFF)
        packet[7] = UInt8((rdtr >> 24) & 0xFF)

        let copyLen = min(data.count, 8)
        for i in 0..<copyLen {
            packet[8 + i] = data[data.startIndex + i]
        }
        return packet
    }

    /// Unpacks 16-byte STM32F4 bxCAN mailbox packets received on USB EP1 IN or UDP port 1338.
    /// Automatically filters out Panda TX receipt echoes (`bus & 0x80 != 0`) unless `includeTxEcho` is true.
    public static func unpackBxCAN16(data: Data, includeTxEcho: Bool = false) -> [PandaCANFrame] {
        var frames: [PandaCANFrame] = []
        var offset = data.startIndex
        while offset + 16 <= data.endIndex {
            let rir = UInt32(data[offset]) |
                      (UInt32(data[offset + 1]) << 8) |
                      (UInt32(data[offset + 2]) << 16) |
                      (UInt32(data[offset + 3]) << 24)
            let rdtr = UInt32(data[offset + 4]) |
                       (UInt32(data[offset + 5]) << 8) |
                       (UInt32(data[offset + 6]) << 16) |
                       (UInt32(data[offset + 7]) << 24)
            offset += 16

            guard rir != 0 else { continue }
            let rawBus = UInt8((rdtr >> 4) & 0xFF)
            let isTxReceipt = (rawBus & 0x80) != 0
            if isTxReceipt && !includeTxEcho {
                continue
            }
            let dlc = min(Int(rdtr & 0xF), 8)
            let isExtended = (rir & 0x4) != 0
            let address = isExtended ? ((rir >> 3) & 0x1FFF_FFFF) : ((rir >> 21) & 0x7FF)
            let payloadStart = offset - 8
            let payload = Data(data[payloadStart..<(payloadStart + dlc)])
            frames.append(PandaCANFrame(address: address, data: payload, bus: rawBus & 0x7F, isTxReceipt: isTxReceipt))
        }
        return frames
    }

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

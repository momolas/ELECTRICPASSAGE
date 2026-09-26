import Foundation

/// Type de charge utile DoIP standardisé selon l'ISO 13400-2.
public enum DoIPPayloadType: UInt16, Sendable, Codable {
    case genericDoIPHeaderNegativeAck = 0x0000
    case vehicleIdentificationRequest = 0x0001
    case vehicleIdentificationRequestWithEID = 0x0002
    case vehicleIdentificationRequestWithVIN = 0x0003
    case vehicleAnnouncementMessage = 0x0004
    case routingActivationRequest = 0x0005
    case routingActivationResponse = 0x0006
    case aliveCheckRequest = 0x0007
    case aliveCheckResponse = 0x0008
    
    case doipEntityStatusRequest = 0x4001
    case doipEntityStatusResponse = 0x4002
    case diagnosticPowerModeInfoRequest = 0x4003
    case diagnosticPowerModeInfoResponse = 0x4004
    
    case diagnosticMessage = 0x8001
    case diagnosticPositiveAck = 0x8002
    case diagnosticNegativeAck = 0x8003
}

/// Structure d'un message DoIP complet (En-tête de 8 octets + Charge utile).
public struct DoIPMessage: Sendable, Equatable {
    public let protocolVersion: UInt8
    public let inverseProtocolVersion: UInt8
    public let payloadType: DoIPPayloadType
    public let payload: Data

    public init(
        protocolVersion: UInt8 = 0x02,
        payloadType: DoIPPayloadType,
        payload: Data = Data()
    ) {
        self.protocolVersion = protocolVersion
        self.inverseProtocolVersion = ~protocolVersion
        self.payloadType = payloadType
        self.payload = payload
    }

    /// Encode le message en flux d'octets DoIP conforme ISO 13400 (8 octets d'en-tête + payload).
    public func encode() -> Data {
        var data = Data()
        data.append(protocolVersion)
        data.append(inverseProtocolVersion)
        data.append(UInt8((payloadType.rawValue >> 8) & 0xFF))
        data.append(UInt8(payloadType.rawValue & 0xFF))
        
        let length = UInt32(payload.count)
        data.append(UInt8((length >> 24) & 0xFF))
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        
        data.append(payload)
        return data
    }

    /// Décode un flux binaire en message DoIP.
    public static func decode(from data: Data) -> DoIPMessage? {
        guard data.count >= 8 else { return nil }
        
        let version = data[data.startIndex]
        let invVersion = data[data.startIndex + 1]
        guard (version ^ invVersion) == 0xFF else { return nil }
        
        let typeRaw = (UInt16(data[data.startIndex + 2]) << 8) | UInt16(data[data.startIndex + 3])
        guard let payloadType = DoIPPayloadType(rawValue: typeRaw) else { return nil }
        
        let length = (UInt32(data[data.startIndex + 4]) << 24) |
                     (UInt32(data[data.startIndex + 5]) << 16) |
                     (UInt32(data[data.startIndex + 6]) << 8)  |
                      UInt32(data[data.startIndex + 7])
        
        let payloadStart = data.startIndex + 8
        guard Int.max - payloadStart >= Int(length) else { return nil }
        let payloadEnd = payloadStart + Int(length)
        guard data.endIndex >= payloadEnd else { return nil }
        
        let payload = data.subdata(in: payloadStart..<payloadEnd)
        return DoIPMessage(protocolVersion: version, payloadType: payloadType, payload: payload)
    }
}

import Foundation

/// Convertisseur de profils Renault / DDT2000 vers le Schéma JSON Universel (UnifiedECUProfile)
public enum DDT2UnifiedConverter {

    /// Structure intermédiaire représentant le JSON brut de base DDT2000 / PyRen
    public struct DDT2000RawDatabase: Decodable, Sendable {
        public let ecuname: String?
        public let obd: DDT2000RawOBD?
        public let data: [String: DDT2000RawData]?
        public let requests: [DDT2000RawRequest]?

        public init(ecuname: String?, obd: DDT2000RawOBD?, data: [String: DDT2000RawData]?, requests: [DDT2000RawRequest]?) {
            self.ecuname = ecuname
            self.obd = obd
            self.data = data
            self.requests = requests
        }
    }

    public struct DDT2000RawOBD: Decodable, Sendable {
        public let protocolName: String?
        public let send_id: String?
        public let recv_id: String?
        public let baudrate: Int?
        public let funcaddr: String?

        public init(protocolName: String? = nil, send_id: String? = nil, recv_id: String? = nil, baudrate: Int? = nil, funcaddr: String? = nil) {
            self.protocolName = protocolName
            self.send_id = send_id
            self.recv_id = recv_id
            self.baudrate = baudrate
            self.funcaddr = funcaddr
        }

        enum CodingKeys: String, CodingKey {
            case protocolName = "protocol"
            case send_id, recv_id, baudrate, funcaddr
        }
    }

    public struct DDT2000RawData: Decodable, Sendable {
        public let bitscount: Int?
        public let bytescount: Int?
        public let scaled: Bool?
        public let signed: Bool?
        public let step: Double?
        public let offset: Double?
        public let format: String?
        public let unit: String?
        public let comment: String?

        public init(
            bitscount: Int? = nil,
            bytescount: Int? = nil,
            scaled: Bool? = nil,
            signed: Bool? = nil,
            step: Double? = nil,
            offset: Double? = nil,
            format: String? = nil,
            unit: String? = nil,
            comment: String? = nil
        ) {
            self.bitscount = bitscount
            self.bytescount = bytescount
            self.scaled = scaled
            self.signed = signed
            self.step = step
            self.offset = offset
            self.format = format
            self.unit = unit
            self.comment = comment
        }
    }

    public struct DDT2000RawRequest: Decodable, Sendable {
        public let sentbytes: String
        public let name: String
        public let receivebyte_dataitems: [String: DDT2000RawReceiveItem]?

        public init(sentbytes: String, name: String, receivebyte_dataitems: [String: DDT2000RawReceiveItem]? = nil) {
            self.sentbytes = sentbytes
            self.name = name
            self.receivebyte_dataitems = receivebyte_dataitems
        }
    }

    public struct DDT2000RawReceiveItem: Decodable, Sendable {
        public let firstbyte: Int
        public let bitoffset: Int?
        public let ref: Bool?

        public init(firstbyte: Int, bitoffset: Int? = nil, ref: Bool? = nil) {
            self.firstbyte = firstbyte
            self.bitoffset = bitoffset
            self.ref = ref
        }
    }

    /// Convertit des données JSON DDT2000 brutes en `UnifiedECUProfile`
    public static func convert(jsonData: Data) throws -> UnifiedECUProfile {
        let decoder = JSONDecoder()
        let ddt = try decoder.decode(DDT2000RawDatabase.self, from: jsonData)

        let ecuName = ddt.ecuname ?? "ECU_Renault"
        let txId = ddt.obd?.send_id ?? "7E0"
        let rxId = ddt.obd?.recv_id ?? "7E8"
        let baudrate = ddt.obd?.baudrate ?? 500000
        let proto = ddt.obd?.protocolName ?? "CAN"

        let connection = UnifiedConnection(
            busType: "CAN",
            baudrate: baudrate,
            txId: txId.hasPrefix("0x") ? txId : "0x\(txId)",
            rxId: rxId.hasPrefix("0x") ? rxId : "0x\(rxId)",
            protocolName: proto
        )

        var downloadServices: [UnifiedService] = []
        var actuationServices: [UnifiedService] = []
        var functionServices: [UnifiedService] = []
        let dataDefs = ddt.data ?? [:]

        for req in (ddt.requests ?? []) {
            let sentBytes = req.sentbytes.replacing( " ", with: "").uppercased()
            let reqName = req.name.isEmpty ? "Req_\(sentBytes)" : req.name

            var outputParams: [UnifiedParameter] = []

            if let items = req.receivebyte_dataitems {
                for (paramName, itemRef) in items {
                    guard let dataDef = dataDefs[paramName] else { continue }

                    let bitsCount = dataDef.bitscount ?? ((dataDef.bytescount ?? 1) * 8)
                    let startBit = ((itemRef.firstbyte - 1) * 8) + (itemRef.bitoffset ?? 0)

                    let step = dataDef.step ?? 1.0
                    let offset = dataDef.offset ?? 0.0
                    let format: UnifiedDataFormat

                    if step != 1.0 || offset != 0.0 {
                        format = .linear(multiplier: step, offset: offset)
                    } else if bitsCount == 1 {
                        format = .boolFlag(posName: "Actif", negName: "Inactif")
                    } else {
                        format = .identical
                    }

                    let param = UnifiedParameter(
                        name: paramName,
                        unit: dataDef.unit ?? "",
                        startBit: startBit,
                        lengthBits: bitsCount,
                        byteOrder: .bigEndian,
                        dataFormat: format
                    )
                    outputParams.append(param)
                }
            }

            let service = UnifiedService(
                name: reqName,
                description: "Commande DDT2000 \(sentBytes)",
                payloadHex: sentBytes,
                inputParams: [],
                outputParams: outputParams
            )

            // Catégorisation intelligente par code de service
            if sentBytes.hasPrefix("30") || sentBytes.hasPrefix("2F") {
                actuationServices.append(service)
            } else if sentBytes.hasPrefix("11") || sentBytes.hasPrefix("31") {
                functionServices.append(service)
            } else {
                downloadServices.append(service)
            }
        }

        let variant = UnifiedVariant(
            name: "\(ecuName)_DefaultVariant",
            description: "Profil extrait de la base DDT2000",
            patterns: [UnifiedPattern(vendor: "Renault", vendorId: ecuName)],
            errors: [],
            downloads: downloadServices,
            actuations: actuationServices,
            adjustments: [],
            functions: functionServices
        )

        return UnifiedECUProfile(
            name: ecuName,
            description: "Profil déclaratif unifié converti automatiquement",
            connections: [connection],
            variants: [variant]
        )
    }

    /// Exporte un `UnifiedECUProfile` au format JSON indenté
    public static func exportToJSON(profile: UnifiedECUProfile) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profile)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "DDT2UnifiedConverter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Erreur d'encodage UTF-8"])
        }
        return jsonString
    }
}

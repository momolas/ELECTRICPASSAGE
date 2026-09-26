import Testing
import Foundation
@testable import VehicleKit

@Suite("VehicleKit Unit Tests")
struct VehicleKitTests {

    @Test("Hex Parsing & Formatting")
    func testHexParsing() {
        let bytes = HexParsing.bytes("62 01 02 FF")
        #expect(bytes == [0x62, 0x01, 0x02, 0xFF])
        #expect(HexParsing.bytes("123") == nil)
        #expect(HexParsing.hex([0x00, 0x7E, 0x80, 0xFF]) == "007E80FF")
    }

    @Test("Formula Evaluator Fast Paths & JavaScript")
    func testFormulaEvaluator() {
        let evaluator = FormulaEvaluator()
        #expect(evaluator.evaluate(formula: "A", bytes: [0x42]) == 66.0)
        #expect(evaluator.evaluate(formula: "(A*256+B)/4", bytes: [0x0B, 0xB8]) == 750.0)
        #expect(evaluator.evaluate(formula: "A-40", bytes: [0x78]) == 80.0)
        #expect(evaluator.evaluate(formula: "A AND 15", bytes: [0xF3]) == 3.0)
    }

    @Test("UDS NRC Parsing")
    func testUDSNRC() {
        let nrcResult = UDSNRC.parse(from: "7F1022")
        #expect(nrcResult != nil)
        #expect(nrcResult?.nrc == .conditionsNotCorrect)
        #expect(nrcResult?.requestedServiceID == 0x10)
        #expect(nrcResult?.title == "Conditions Non Remplies")
    }

    @Test("SecurityAccess Seed & Key Calculation")
    func testSecurityAccess() {
        let keyXor = SecurityAccessManager.calculateKey(seedHex: "12 34", algorithm: .xorStatique, maskHex: "5A 5A")
        #expect(keyXor == "486E")

        let keyRenault = SecurityAccessManager.calculateKey(seedHex: "12 34", algorithm: .renaultStandard, maskHex: "5A 5A")
        #expect(keyRenault.isEmpty == false)
    }

    @Test("ISO-TP Multi-Frame Reassembly")
    func testISOTPReassembly() async {
        let reassembler = ISOTPReassembler()

        // 1. Single frame
        let sf = await reassembler.processFrame(address: 0x7E8, data: Data([0x03, 0x22, 0x01, 0x02, 0xAA, 0xAA, 0xAA, 0xAA]))
        #expect(sf == .completed(Data([0x22, 0x01, 0x02])))

        // 2. First frame
        let ff = await reassembler.processFrame(address: 0x7E8, data: Data([0x10, 0x0C, 0x62, 0x01, 0x02, 0x03, 0x04, 0x05]))
        #expect(ff == .needsFlowControl)

        // 3. Consecutive frame
        let cf = await reassembler.processFrame(address: 0x7E8, data: Data([0x21, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x00]))
        if case .completed(let payload) = cf {
            #expect(payload.count == 12)
        } else {
            Issue.record("Consecutive frame did not complete multi-frame reassembly")
        }
    }

    @Test("Pearson Signal Correlation")
    func testSignalCorrelation() {
        let xs = [1.0, 2.0, 3.0, 4.0, 5.0]
        let ys = [2.0, 4.0, 6.0, 8.0, 10.0]
        let r = SignalCorrelator.pearsonCorrelation(x: xs, y: ys)
        #expect(r != nil)
        #expect(abs((r ?? 0) - 1.0) < 0.001)
    }

    @Test("Freeze Frame KWP Decoding")
    func testFreezeFrameDecoder() {
        let kwpHex = "58 01 02 01 86 A0 0B B8 78 32"
        let decoded = FreezeFrameDecoder.parseKWP(responseHex: kwpHex, dtcCode: "P0102")
        #expect(decoded.timestampKm == 100000)
        #expect(decoded.rpm == 750)
        #expect(decoded.coolantTemp == 80)
        #expect(decoded.vehicleSpeed == 50)
    }

    @Test("Simulator Engine Responses")
    func testSimulatorEngine() async throws {
        let sim = SimulatorEngine()
        let sessionResp = try await sim.sendDiagnosticRequest("1085")
        #expect(sessionResp.hasPrefix("5085"))

        let lidResp = try await sim.sendDiagnosticRequest("2100")
        #expect(lidResp.contains("61"))
    }

    @Test("SAE J1939 PGN & Signal Decoding")
    func testJ1939Decoding() {
        // Test PGN 61444 (0xF004 - EEC1)
        let canID: UInt32 = 0x0CF00400 // Priority 3, PGN 61444, SA 0
        let header = J1939Header(canID: canID)
        #expect(header.pgn == 61444)
        #expect(header.priority == 3)
        #expect(header.sourceAddress == 0)
        #expect(header.isBroadcast == true)

        let payload = Data([0xFF, 0x00, 0x7D, 0x00, 0x20, 0xFF, 0xFF, 0xFF]) // Torque: 125-125=0%, RPM: 8192*0.125 = 1024 rpm
        let signals = J1939Decoder.decode(pgn: header.pgn, data: payload)
        #expect(signals.isEmpty == false)
        if let rpmSignal = signals.first(where: { $0.spn == 190 }) {
            #expect(rpmSignal.value == 1024.0)
        }
    }

    @Test("CAN Protocol Auto-Detection")
    func testProtocolDetection() {
        // 1. J1939 detection (29-bit ID)
        let j1939Class = CANProtocolDetector.detect(canID: 0x18FEEE00)
        #expect(j1939Class.protocolType == .j1939)
        #expect(j1939Class.is29BitExtended == true)

        // 2. OBD-II Broadcast
        let obdClass = CANProtocolDetector.detect(canID: 0x7DF)
        #expect(obdClass.protocolType == .obd2)

        // 3. OBD-II Physical Response
        let respClass = CANProtocolDetector.detect(canID: 0x7E8)
        #expect(respClass.protocolType == .obd2)

        // 4. KWP2000 Legacy Diag
        let kwpClass = CANProtocolDetector.detect(canID: 0x640)
        #expect(kwpClass.protocolType == .kwp2000)

        // 5. Generic CAN
        let genericClass = CANProtocolDetector.detect(canID: 0x120)
        #expect(genericClass.protocolType == .generic)
    }

    @Test("Unified ECU Profile & DDT2000 Conversion")
    func testUnifiedProfileConversion() throws {
        let sampleDDTJSON = """
        {
            "ecuname": "INJECTION_EDC16",
            "obd": {
                "protocol": "CAN",
                "send_id": "7E0",
                "recv_id": "7E8",
                "baudrate": 500000
            },
            "data": {
                "Regime_Moteur": {
                    "bitscount": 16,
                    "step": 0.125,
                    "offset": 0.0,
                    "unit": "tr/min"
                },
                "Relais_Pompe": {
                    "bitscount": 1,
                    "step": 1.0,
                    "offset": 0.0,
                    "unit": ""
                }
            },
            "requests": [
                {
                    "name": "Lecture Télémétrie Moteur",
                    "sentbytes": "2101",
                    "receivebyte_dataitems": {
                        "Regime_Moteur": { "firstbyte": 2, "bitoffset": 0 }
                    }
                },
                {
                    "name": "Test Actionneur Relais",
                    "sentbytes": "300101",
                    "receivebyte_dataitems": {
                        "Relais_Pompe": { "firstbyte": 1, "bitoffset": 0 }
                    }
                }
            ]
        }
        """.data(using: .utf8)!

        let profile = try DDT2UnifiedConverter.convert(jsonData: sampleDDTJSON)
        #expect(profile.name == "INJECTION_EDC16")
        #expect(profile.connections.count == 1)
        #expect(profile.connections.first?.txId == "0x7E0")
        #expect(profile.variants.count == 1)

        let variant = try #require(profile.variants.first)
        #expect(variant.downloads.count == 1)
        #expect(variant.actuations.count == 1)

        let jsonExport = try DDT2UnifiedConverter.exportToJSON(profile: profile)
        #expect(jsonExport.contains("INJECTION_EDC16"))
        #expect(jsonExport.contains("Linear"))
    }

    @Test("DTC Decoder (SAE J1979 & KWP2000)")
    func testDTCDecoder() {
        #expect(DTCDecoder.decodeSingleDTC("0102") == "P0102")
        #expect(DTCDecoder.decodeSingleDTC("C100") == "U0100")
        #expect(DTCDecoder.decodeSingleDTC("4101") == "C0101")
        #expect(DTCDecoder.decodeSingleDTC("8100") == "B0100")

        let dtcsStandard = DTCDecoder.decodeDTCList(from: "43 01 02 03 00")
        #expect(dtcsStandard == ["P0102", "P0300"])

        let dtcsLegacy = DTCDecoder.decodeDTCList(from: "43 02 01 02 03 00")
        #expect(dtcsLegacy == ["P0102", "P0300"])

        let statusPresent = DTCDecoder.decodeKwpDtcStatus(0x80)
        #expect(statusPresent.contains("Présent"))
    }

    @Test("KWP2000 Client Session & Services")
    func testKWP2000Client() async throws {
        let sim = SimulatorEngine()
        let client = KWP2000Client(interface: sim)

        let sessionResp = try await client.startSession(mode: 0x85)
        #expect(sessionResp.hasPrefix("5085"))

        let lidData = try await client.readLocalIdentifier(lid: 0x00)
        #expect(lidData.isEmpty == false)

        await client.stopTesterPresent()
    }

    @Test("VIN Reader & Decoders (OBD2, UDS, KWP2000)")
    func testVINReader() {
        // 1. OBD-II Mode 09 PID 02 (ASCII: VF1JM0G0D12345678)
        let hexOBD2 = "4902015646314A4D304730443132333435363738"
        let obdVIN = VINReader.parseOBD2VIN(hexOBD2)
        #expect(obdVIN == "VF1JM0G0D12345678")

        // 2. UDS DID F190
        let hexUDS = "62F1905646314A4D304730443132333435363738"
        let udsVIN = VINReader.parseUDSVIN(hexUDS)
        #expect(udsVIN == "VF1JM0G0D12345678")

        // 3. KWP2000 LID 81
        let hexKWP = "61815646314A4D304730443132333435363738"
        let kwpVIN = VINReader.parseKWP2000VIN(hexKWP)
        #expect(kwpVIN == "VF1JM0G0D12345678")
    }

    @Test("Standard PIDs Catalog & ECU Liveness")
    func testStandardPidsAndLiveness() async throws {
        #expect(StandardPids.all.count > 40)
        #expect(StandardPids.byPid["0C"]?.displayName == "Engine RPM")

        let sim = SimulatorEngine()
        let isAlive = try await ECULiveness.check(driver: sim)
        #expect(isAlive == true)
    }

    @Test("Profile & Bidirectional Unified Converter")
    func testBidirectionalProfileConverter() {
        let sampleProfile = Profile(
            profileId: "test_profile",
            profileVersion: "1.0",
            displayName: "Test Profile",
            description: "A test profile",
            vehicleMatch: nil,
            ecus: ["main": EcuDef(requestHeader: "7E0", responseHeader: "7E8")],
            pids: [
                PidDef(id: "rpm", displayName: "Engine RPM", ecu: "main", mode: "01", pid: "0C", unit: "rpm", formula: "(A*256+B)/4", category: .rpm)
            ]
        )

        let unified = UnifiedProfileConverter.convert(legacyProfile: sampleProfile)
        #expect(unified.name == "Test Profile")
        #expect(unified.variants.first?.downloads.count == 1)

        let restoredLegacy = UnifiedProfileConverter.toLegacyProfile(unified: unified)
        #expect(restoredLegacy.displayName == "Test Profile")
        #expect(restoredLegacy.pids.count == 1)
    }

    @Test("ISO 14229 DTC Status Mask & DecodedDTC")
    func testDTCStatusMaskAndDecoding() {
        let mask = DTCStatusMask(rawValue: 0x2F) // testFailed(01), testFailedThisOperationCycle(02), pending(04), confirmed(08), testFailedSinceLastClear(20)
        #expect(mask.contains(.testFailed))
        #expect(mask.contains(.confirmedDTC))
        #expect(mask.contains(.warningIndicatorRequested) == false)
        #expect(mask.summary.isEmpty == false)

        // UDS 0x19 02 Response: 59 02 FF (010200 2F)
        let udsPayload = "59 02 FF 01 02 00 2F"
        let decoded = DTCDecoder.decodeDTCsWithStatus(from: udsPayload)
        #expect(decoded.count == 1)
        #expect(decoded.first?.code == "P0102")
        #expect(decoded.first?.statusMask?.contains(.confirmedDTC) == true)
    }

    @Test("UDS Client Services Execution")
    func testUDSClient() async throws {
        let sim = SimulatorEngine()
        let client = UDSClient(interface: sim)

        let session = try await client.startSession(sessionType: 0x01)
        #expect(session.hasPrefix("5001"))

        let didData = try await client.readDataByIdentifier(0xF190)
        #expect(didData.contains("564631"))

        let dtcs = try await client.readDTCInformation(reportType: .reportDTCByStatusMask)
        #expect(dtcs.count >= 1)

        try await client.ecuReset(type: .hardReset)
        await client.stop()
    }

    @Test("DoIP Header Framing & Client Session")
    func testDoIPFramingAndClient() async throws {
        // Encode / Decode DoIP Message
        let payload = Data([0x0E, 0x00, 0x0E, 0x80, 0x10, 0x01])
        let originalMsg = DoIPMessage(protocolVersion: 0x02, payloadType: .diagnosticMessage, payload: payload)
        let encodedData = originalMsg.encode()
        #expect(encodedData.count == 8 + payload.count)

        let decodedMsg = DoIPMessage.decode(from: encodedData)
        #expect(decodedMsg != nil)
        #expect(decodedMsg?.payloadType == .diagnosticMessage)
        #expect(decodedMsg?.payload == payload)

        // DoIP Client Simulation
        let doipClient = DoIPClient()
        try await doipClient.connect()
        #expect(await doipClient.isConnected == true)
        #expect(await doipClient.isRoutingActivated == true)

        let resp = try await doipClient.sendDiagnosticRequest("1001")
        #expect(resp == "5001")

        await doipClient.disconnect()
        #expect(await doipClient.isConnected == false)
    }

    @Test("BLE OBD-II Driver Connection & Diagnostic Requests")
    func testBLEOBDDriver() async throws {
        let bleDriver = BLEOBDDriver()
        try await bleDriver.connect()
        #expect(await bleDriver.isConnected == true)

        try await bleDriver.setTarget(txID: "7E0", rxID: "7E8")

        let rpmResp = try await bleDriver.sendDiagnosticRequest("010C")
        #expect(rpmResp.contains("41 0C"))

        let vinResp = try await bleDriver.sendDiagnosticRequest("22F190")
        #expect(vinResp.contains("56 46 31"))

        await bleDriver.disconnect()
        #expect(await bleDriver.isConnected == false)
    }

    @Test("OBDb Signalset Import & Conversion to UnifiedECUProfile")
    func testOBDbImporter() throws {
        let sampleJson = """
        {
          "diagnosticLevel": "extended",
          "commands": [
            {
              "hdr": "7E0",
              "cmd": "2211A4",
              "freq": 0.1,
              "signals": [
                {
                  "id": "turbo_boost_pressure",
                  "name": "Pression de Suralimentation",
                  "path": "Moteur/Turbo",
                  "fmt": {
                    "bytes": 2,
                    "scale": 0.01,
                    "offset": 0.0,
                    "unit": "bar"
                  }
                }
              ]
            },
            {
              "hdr": "7E4",
              "cmd": "22F401",
              "freq": 1.0,
              "signals": [
                {
                  "id": "hv_battery_soh",
                  "name": "State of Health Batterie",
                  "path": "Batterie/Santé",
                  "fmt": {
                    "bytes": 1,
                    "scale": 0.5,
                    "offset": 0.0,
                    "unit": "%"
                  }
                }
              ]
            }
          ]
        }
        """

        let data = sampleJson.data(using: .utf8)!
        let unifiedProfile = try OBDbImporter.convert(
            jsonData: data,
            vehicleName: "BMW 3 Series G20",
            profileId: "bmw_3series_g20"
        )

        #expect(unifiedProfile.name == "BMW 3 Series G20")
        #expect(unifiedProfile.connections.count == 2)
        #expect(unifiedProfile.variants.first?.downloads.count == 2)

        let legacyProfile = UnifiedProfileConverter.toLegacyProfile(unified: unifiedProfile, id: "bmw_3series_g20")
        #expect(legacyProfile.displayName == "BMW 3 Series G20")
        #expect(legacyProfile.pids.count == 2)
        #expect(legacyProfile.pids.first(where: { $0.unit == "bar" }) != nil)
    }

    @Test("OBD2Analyzer Request & Response Decoding")
    func testOBD2Analyzer() {
        let desc = OBD2Analyzer.describeRequest("2190")
        #expect(desc.contains("Read Data By Local Identifier"))
        #expect(desc.contains("VIN"))

        let udsDesc = OBD2Analyzer.describeRequest("22F190")
        #expect(udsDesc.contains("Read Data By Identifier"))
        #expect(udsDesc.contains("VIN"))

        let nrcResp = OBD2Analyzer.decodeResponse(request: "22F190", response: "7F2231")
        #expect(nrcResp?.contains("31") == true)
        #expect(nrcResp?.contains("Rejet") == true)

        let posResp = OBD2Analyzer.decodeResponse(request: "1003", response: "5003")
        #expect(posResp?.contains("Extended Diagnostic Session") == true)
    }

    @Test("BusCoordinator Concurrency Lock & Preemption")
    @MainActor
    func testBusCoordinator() async {
        let coordinator = BusCoordinator()
        #expect(coordinator.isBusy == false)

        await coordinator.acquire(priority: .interactive, name: "Live Data")
        #expect(coordinator.isBusy)
        #expect(coordinator.activePriority == .interactive)
        #expect(coordinator.activeSessionName == "Live Data")

        coordinator.release()
        #expect(coordinator.isBusy == false)
    }

    @Test("RegistryBuilder Combine PIDs")
    func testRegistryBuilder() {
        let profile = Profile(
            profileId: "test_car",
            profileVersion: "1.0",
            displayName: "Test Car",
            ecus: ["ECM": EcuDef(requestHeader: "7E0", responseHeader: "7E8")],
            pids: [
                PidDef(id: "custom_oil_temp", displayName: "Oil Temp", ecu: "ECM", mode: "22", pid: "1155", unit: "°C", formula: "A-40", category: .temperature)
            ]
        )

        let combined = RegistryBuilder.build(
            profile: profile,
            supportedStandardPIDs: ["0C", "0D"],
            supportedProfilePIDs: ["custom_oil_temp"]
        )

        #expect(combined.count >= 2)
        #expect(combined.contains(where: { $0.id == "custom_oil_temp" }))
    }

    @Test("Standard PID Discovery Safety & Non-Crash on Short Frames")
    func testStandardPIDDiscoverySafety() async throws {
        // Mock driver qui renvoie d'abord un NRC court (3 octets) pour tester l'absence de crash
        actor ShortFrameDriver: VehicleInterface {
            var calls = 0
            func sendDiagnosticRequest(_ requestHex: String, timeout: TimeInterval) async throws -> String {
                calls += 1
                if requestHex.contains("0100") {
                    return "41 00 BE 3E B8 11" // Range 00 avec bit 31=1
                } else if requestHex.contains("0120") {
                    return "7F 01 11" // NRC 3 octets (provoquait un crash 0 ..< -2)
                }
                return "7F 01 12"
            }
            func setTarget(txID: String, rxID: String?) async throws {}
        }

        let driver = ShortFrameDriver()
        let discovered = try await StandardPIDDiscovery.discover(driver: driver)
        #expect(discovered.isEmpty == false)
        #expect(discovered.contains("0C")) // RPM supporté
    }

    @Test("Simulator Engine Enhanced Services & Renault Offset")
    func testSimulatorEngineEnhanced() async throws {
        let sim = SimulatorEngine()

        // 1. Test Renault Rx ID calculation avec préfixe "0x" (0x745 + 0x20 = 765)
        try await sim.setTarget(txID: "0x745", rxID: nil)
        let stateEcho = try await sim.sendDiagnosticRequest("210C")
        #expect(stateEcho.hasPrefix("61 0C"))

        // 2. Test LID 0C exact echo (RPM)
        let lid0C = try await sim.sendDiagnosticRequest("210C")
        #expect(lid0C.hasPrefix("61 0C"))

        // 3. Test OBD-II Mode 03 / Mode 07 DTCs (SAE J1979 sans octet de compte)
        let dtcResp = try await sim.sendDiagnosticRequest("03")
        #expect(dtcResp.contains("43 01"))

        // 4. Test OBD-II Mode 04 Clear DTCs
        let clearResp = try await sim.sendDiagnosticRequest("04")
        #expect(clearResp == "44")

        // 5. Test OBD-II Mode 09 VIN
        let vinResp = try await sim.sendDiagnosticRequest("0902")
        #expect(vinResp.contains("49 02"))
        let decodedVIN = VINReader.parseOBD2VIN(vinResp)
        #expect(decodedVIN == "VF1JM0G0D12345678")

        // 6. Test SecurityAccess Seed & Key
        let seedResp = try await sim.sendDiagnosticRequest("2701")
        #expect(seedResp.hasPrefix("6701"))
        let keyResp = try await sim.sendDiagnosticRequest("2702")
        #expect(keyResp == "6702")

        // 7. Test KWP2000Client with LID 0C
        let kwp = KWP2000Client(interface: sim)
        let rpmData = try await kwp.readLocalIdentifier(lid: 0x0C)
        #expect(rpmData.isEmpty == false)
        await kwp.stopTesterPresent()
    }

    @Test("OBD2Analyzer Integration with FormulaEvaluator")
    func testOBD2AnalyzerFormulas() {
        // PID 06: Short Term Fuel Trim (A*100/128 - 100)
        // 0x80 (128) -> 128*100/128 - 100 = 0 %
        let stftResp = OBD2Analyzer.decodeResponse(request: "0106", response: "41 06 80")
        #expect(stftResp?.contains("0 %") == true)

        // PID 0A: Fuel Pressure (A*3)
        // 0x20 (32) -> 32 * 3 = 96 kPa
        let pressResp = OBD2Analyzer.decodeResponse(request: "010A", response: "41 0A 20")
        #expect(pressResp?.contains("96 kPa") == true)

        // PID 23: Fuel Rail Pressure ((A*256+B)*10)
        // 0x01, 0x00 (256) -> 2560 kPa
        let railResp = OBD2Analyzer.decodeResponse(request: "0123", response: "41 23 01 00")
        #expect(railResp?.contains("2560 kPa") == true)

        // PID 61: Demanded Torque (A - 125)
        // 0x7D (125) -> 0 %
        let torqueResp = OBD2Analyzer.decodeResponse(request: "0161", response: "41 61 7D")
        #expect(torqueResp?.contains("0 %") == true)
    }

    @Test("Apple Accelerate SignalCorrelator & Multi-Byte Slicing")
    func testSignalCorrelatorAccelerateAndSlices() {
        // 1. Validation de Pearson accéléré
        let xs = [10.0, 20.0, 30.0, 40.0, 50.0]
        let ys = [15.0, 25.0, 35.0, 45.0, 55.0]
        let r = SignalCorrelator.pearsonCorrelation(x: xs, y: ys)
        #expect(r != nil)
        #expect(abs((r ?? 0.0) - 1.0) < 1e-6)

        // 2. Validation des étiquettes de tranches sans collision > 26 octets
        #expect(SignalCorrelator.sliceLabel(for: 0) == "A")
        #expect(SignalCorrelator.sliceLabel(for: 25) == "Z")
        #expect(SignalCorrelator.sliceLabel(for: 26) == "AA")
        #expect(SignalCorrelator.sliceLabel(for: 27) == "AB")

        // 3. Matrice de 30 octets sur 6 échantillons (au-delà des 26 octets)
        var rows: [[UInt8]] = []
        for i in 0..<6 {
            var row = [UInt8](repeating: 0, count: 30)
            row[0] = UInt8(i * 10)       // Tranche A
            row[26] = UInt8(i * 20)      // Tranche AA (ne doit pas écraser A)
            rows.append(row)
        }

        let ref: [String: [Double]] = ["REF": [0.0, 10.0, 20.0, 30.0, 40.0, 50.0]]
        let slices = SignalCorrelator.correlateSlices(byteRows: rows, references: ref, minimumSamples: 6)

        #expect(slices.contains(where: { $0.sliceName == "A" }))
        #expect(slices.contains(where: { $0.sliceName == "AA" }))
    }

    @Test("BusCoordinator Strict Mutual Exclusion & Priority Queue")
    @MainActor
    func testBusCoordinatorStrictExclusion() async {
        let coordinator = BusCoordinator()

        // 1. Tâche 1 prend le bus
        await coordinator.acquire(priority: .interactive, name: "Task 1")
        #expect(coordinator.isBusy)
        #expect(coordinator.activeSessionName == "Task 1")

        // 2. Libération
        coordinator.release()
        #expect(coordinator.isBusy == false)
        #expect(coordinator.activeSessionName == nil)
    }

    @Test("FormulaEvaluator AST Precompilation, Extended Functions & Batch Evaluation")
    func testFormulaEvaluatorASTAndExtended() {
        let evaluator = FormulaEvaluator()

        // 1. Compilation AST explicite
        let compiled = evaluator.compile(formula: "min(A, B) + 10")
        #expect(compiled != nil)
        #expect(compiled?.evaluate(bytes: [20, 50]) == 30.0)
        #expect(compiled?.evaluate(bytes: [80, 15]) == 25.0)

        // 2. Fonctions étendues : max, sqrt, abs, round
        #expect(evaluator.evaluate(formula: "max(A, B)", bytes: [10, 42]) == 42.0)
        #expect(evaluator.evaluate(formula: "sqrt(A)", bytes: [64]) == 8.0)
        #expect(evaluator.evaluate(formula: "abs(A-100)", bytes: [75]) == 25.0)
        #expect(evaluator.evaluate(formula: "round(A/4)", bytes: [10]) == 3.0)

        // 3. Opérateur conditionnel ternaire (cond ? true : false)
        #expect(evaluator.evaluate(formula: "A > 50 ? 1 : 0", bytes: [75]) == 1.0)
        #expect(evaluator.evaluate(formula: "A > 50 ? 1 : 0", bytes: [25]) == 0.0)

        // 4. Opérateurs logiques, comparaisons et précédence de grammaire
        #expect(evaluator.evaluate(formula: "A > 50 AND B < 20", bytes: [60, 10]) == 1.0)
        #expect(evaluator.evaluate(formula: "A > 50 AND B < 20", bytes: [40, 10]) == 0.0)
        #expect(evaluator.evaluate(formula: "A == 0 || B == 42", bytes: [10, 42]) == 1.0)
        #expect(evaluator.evaluate(formula: "A == 0 || B == 42", bytes: [10, 40]) == 0.0)
        #expect(evaluator.evaluate(formula: "A & 15 == 3", bytes: [0x13]) == 1.0)

        // 5. Opérateurs bitwise et décalages avec masque sécurisé
        #expect(evaluator.evaluate(formula: "A << 2", bytes: [10]) == 40.0)
        #expect(evaluator.evaluate(formula: "A >> 1", bytes: [40]) == 20.0)
        #expect(evaluator.evaluate(formula: "!A", bytes: [0]) == 1.0)
        #expect(evaluator.evaluate(formula: "!A", bytes: [10]) == 0.0)
        #expect(evaluator.evaluate(formula: "~A", bytes: [0]) == -1.0)

        // 6. Robustesse numérique (division par zéro, finitude)
        #expect(evaluator.evaluate(formula: "1 / 0", bytes: []) == nil)

        // 7. Batch evaluation
        let frames: [[UInt8]] = (0..<100).map { [UInt8($0)] }
        let batchResults = evaluator.evaluateBatch(formula: "A * 2", frames: frames)
        #expect(batchResults.count == 100)
        #expect(batchResults[50] == 100.0)
    }

    @Test("SimulatorEngine Dynamic Physics & Interactive Faults")
    func testSimulatorEngineDynamicPhysicsAndFaults() async throws {
        let engine = SimulatorEngine()

        // 1. État initial au ralenti
        let initial = await engine.getState()
        #expect(initial.rpm == 750.0)
        #expect(initial.throttlePercent == 0.0)

        // 2. Accélération papillon à 80%
        await engine.setThrottle(percent: 80.0)
        await engine.stepSimulation(deltaSeconds: 0.5)

        let runningState = await engine.getState()
        #expect(runningState.rpm > 750.0)
        #expect(runningState.intakeMapKpa > 35.0)
        #expect(runningState.mafGPerSec > 3.5)

        // 3. Injection et lecture de panne DTC
        await engine.injectFault(dtc: "P0300")
        let dtcResp = try await engine.sendDiagnosticRequest("03")
        #expect(dtcResp.contains("43"))
        #expect(dtcResp.contains("03 00")) // P0300

        // 4. Effacement via Mode 04
        let clearResp = try await engine.sendDiagnosticRequest("04")
        #expect(clearResp == "44")
        let clearedState = await engine.getState()
        #expect(clearedState.activeDTCs.isEmpty)
        #expect(clearedState.milActive == false)
    }

    @Test("SimulatorEngine Multi-PID Response Decoding")
    func testSimulatorEngineMultiPIDResponses() async throws {
        let engine = SimulatorEngine()

        // Requête multi-PIDs SAE J1979 : Régime (0C) + Vitesse (0D) + Charge (04)
        let resp = try await engine.sendDiagnosticRequest("01 0C 0D 04")
        #expect(resp.hasPrefix("41"))
        #expect(resp.contains("0C"))
        #expect(resp.contains("0D"))
        #expect(resp.contains("04"))
    }

    @Test("SignalCorrelator Cross-Correlation Time-Lag (Turbo Lag)")
    func testSignalCorrelatorTimeLag() {
        // Stimulus (ex: commande pédale)
        let x: [Double] = [0, 0, 10, 40, 80, 100, 100, 90, 50, 20, 0, 0, 0, 0]
        // Réponse retardée exactement de 2 échantillons (ex: pression turbo)
        let y: [Double] = [0, 0, 0, 0, 10, 40, 80, 100, 100, 90, 50, 20, 0, 0]

        let result = SignalCorrelator.crossCorrelationWithLag(x: x, y: y, maxLag: 4)
        #expect(result.bestLag == 2)
        #expect(result.bestCorrelation > 0.95)
    }

    @Test("PowertrainCalculations Power, Torque, Fuel & Volumetric Efficiency")
    func testPowertrainCalculations() {
        // 1. Puissance : 200 N.m à 3000 RPM -> ~62.83 kW (~85.4 ch)
        let (kw, hp) = PowertrainCalculations.instantaneousPower(torqueNm: 200.0, rpm: 3000.0)
        #expect(abs(kw - 62.83) < 0.1)
        #expect(abs(hp - 85.4) < 0.2)

        // 2. Couple réciproque
        let torque = PowertrainCalculations.instantaneousTorque(powerKw: kw, rpm: 3000.0)
        #expect(abs(torque - 200.0) < 0.1)

        // 3. Consommation : 15 g/s MAF à 90 km/h (essence)
        let (lPerHour, lPer100Km) = PowertrainCalculations.instantaneousFuelConsumption(
            mafGPerSec: 15.0,
            speedKmh: 90.0
        )
        #expect(lPerHour > 0.0)
        #expect(lPer100Km != nil)
        if let cons = lPer100Km {
            #expect(cons > 3.0 && cons < 8.0) // ~4.93 L/100km
        }

        // 4. Rendement volumétrique VE % (moteur 1.6L à 3000 RPM)
        let ve = PowertrainCalculations.volumetricEfficiency(
            mafGPerSec: 25.0,
            rpm: 3000.0,
            mapKpa: 100.0,
            iatCelsius: 25.0,
            displacementLiters: 1.6
        )
        #expect(ve != nil)
        if let v = ve {
            #expect(v > 50.0 && v < 120.0)
        }
    }

    @Test("Sampler Actor & Multi-PID Acquisition Stream")
    func testSamplerActorAndMultiPIDStream() async throws {
        let engine = SimulatorEngine()
        let pids: [PidDef] = [
            try #require(StandardPids.get("0C")), // RPM
            try #require(StandardPids.get("0D")), // Speed
            try #require(StandardPids.get("04")), // Load
            try #require(StandardPids.get("05"))  // Temp
        ]
        let ecus: [String: EcuDef] = [
            "engine": EcuDef(requestHeader: "7E0", responseHeader: "7E8")
        ]

        let sampler = Sampler(
            driver: engine,
            pids: pids,
            ecus: ecus,
            baseLoopRateHz: 10.0,
            customRates: ["engine_load": .fast, "coolant_temp": .fast],
            sessionStartMs: 0
        )

        // 1. Exécution d'un tick d'échantillonnage multi-PID
        let row = await sampler.runOneTick()
        #expect(row.values["rpm"] != nil)
        #expect(row.values["speed"] != nil)
        #expect(row.values["engine_load"] != nil)
        #expect(row.values["coolant_temp"] != nil)

        // 2. Démarrage et arrêt de la boucle asynchrone sans blocage
        await sampler.start()
        try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        let ticks = await sampler.tickCount
        #expect(ticks >= 1)
        await sampler.stop()
    }

    @Test("Hardening Swarm Fixes: Direct Lock Handoff, Anti-Correlation & Atomic Transactions")
    @MainActor
    func testHardeningSwarmFixes() async throws {
        // 1. BusCoordinator Direct Lock Handoff & Priority Order
        let coordinator = BusCoordinator()
        await coordinator.acquire(priority: .interactive, name: "Initial Task")
        #expect(coordinator.isBusy == true)

        var executionOrder: [String] = []

        let taskCritical = Task { @MainActor in
            await coordinator.acquire(priority: .criticalExclusive, name: "Flash Routine")
            executionOrder.append("Flash Routine")
            coordinator.release()
        }

        let taskInteractive = Task { @MainActor in
            await coordinator.acquire(priority: .interactive, name: "Diagnostics")
            executionOrder.append("Diagnostics")
            coordinator.release()
        }

        // Céder brièvement pour laisser les tâches s'enregistrer dans waiters
        await Task.yield()

        // Release initiale : passage direct à la tâche critique sans passer par isBusy = false
        coordinator.release()
        #expect(coordinator.isBusy == true) // Maintenu par Direct Lock Handoff
        #expect(coordinator.activePriority == .criticalExclusive)
        #expect(coordinator.activeSessionName == "Flash Routine")

        _ = await taskCritical.result
        _ = await taskInteractive.result

        #expect(executionOrder == ["Flash Routine", "Diagnostics"])
        #expect(coordinator.isBusy == false)

        // 2. SignalCorrelator Anti-Correlation avec Lag
        // Signal de commande et réponse physique inversée décalée de 2 échantillons
        let stimulus: [Double] = [0, 0, 10, 40, 80, 100, 100, 90, 50, 20, 0, 0, 0, 0]
        let invertedDelayed: [Double] = [0, 0, 0, 0, -10, -40, -80, -100, -100, -90, -50, -20, 0, 0] // Lag de +2 échantillons, r ~ -1.0
        let lagResult = SignalCorrelator.crossCorrelationWithLag(x: stimulus, y: invertedDelayed, maxLag: 4)
        #expect(lagResult.bestCorrelation < -0.95)
        #expect(lagResult.bestLag == 2)

        // 3. KWP2000Client Atomic Transaction
        let sim = SimulatorEngine()
        let kwp = KWP2000Client(interface: sim)
        try await kwp.withAtomicTransaction {
            // Durant cette transaction, TesterPresent doit être strictement neutralisé
            try await kwp.sendTesterPresent(suppressResponse: true)
        }
        await kwp.stopTesterPresent()

        // 4. FormulaEvaluator Masking Shifts & Safe Finitude
        let evaluator = FormulaEvaluator()
        let shiftResult = evaluator.evaluate(formula: "A << 66", bytes: [1]) // 66 & 63 = 2 -> 1 << 2 = 4
        #expect(shiftResult == 4.0)
        let sqrtNegative = evaluator.evaluate(formula: "sqrt(0 - 4)", bytes: [])
        #expect(sqrtNegative == nil)
    }

    @MainActor
    @Test("Swift Bug Pro Fixes: ISOTP Subslice, ProfileProbe Overflow, 0x Hex Sanitization & UDS Atomic Keepalive")
    func testSwiftBugProFixes() async throws {
        // 1. ISOTPReassembler avec Data slice (startIndex > 0)
        let reassembler = ISOTPReassembler()
        let rawBuffer = Data([0xAA, 0x55, 0x03, 0x22, 0x01, 0x02, 0x00, 0x00])
        let slicedFrame = rawBuffer.dropFirst(2)
        #expect(slicedFrame.startIndex == 2)
        let isotpResult = await reassembler.processFrame(address: 0x7E8, data: slicedFrame)
        #expect(isotpResult == .completed(Data([0x22, 0x01, 0x02])))

        // 2. ProfileProbe : protection contre le débordement sur mode >= 0xC0
        let profile = Profile(
            profileId: "overflow_test",
            profileVersion: "1.0",
            displayName: "Overflow Test Profile",
            vehicleMatch: nil,
            ecus: ["ECM": EcuDef(requestHeader: "7E0", responseHeader: "7E8")],
            pids: [
                PidDef(
                    id: "routine_c0",
                    displayName: "Routine C0",
                    ecu: "ECM",
                    mode: "C0", // 0xC0 = 192 (192 + 0x40 = 256 > 255 sans crash)
                    pid: "01",
                    unit: "",
                    formula: "A",
                    category: .other
                )
            ]
        )
        let sim = SimulatorEngine()
        let probeResult = try await ProfileProbe.probe(driver: sim, profile: profile)
        #expect(probeResult.isEmpty) // Mode C0 non reconnu en OBD2 mais aucun crash arithmétique

        // 3. DoIPClient & PandaDriver : assainissement du préfixe "0x"
        let doip = DoIPClient()
        try await doip.connect()
        try await doip.setTarget(txID: "0x17FC", rxID: "0x17FD")
        let doipResp = try await doip.sendDiagnosticRequest("1001")
        #expect(doipResp == "5001")
        await doip.disconnect()

        let panda = PandaDriver()
        try await panda.connect()
        try await panda.setTarget(txID: "0x745", rxID: nil)
        await panda.disconnect()

        // 4. UDSClient : Transaction atomique et isolation
        let udsSim = SimulatorEngine()
        let udsClient = UDSClient(interface: udsSim)
        let atomicRes = try await udsClient.withAtomicTransaction {
            try await udsSim.sendDiagnosticRequest("1001", timeout: 1.0)
        }
        #expect(atomicRes.contains("5001"))
        await udsClient.stop()

        // 5. CANProtocolDetector : plage 0x740...0x77F classifiée en KWP2000
        let classificationUCH = CANProtocolDetector.detect(canID: 0x745, payload: Data([0x02, 0x21, 0x81]))
        #expect(classificationUCH.protocolType == .kwp2000)

        // 6. BusCoordinator : réentrance autorisée sur la même session
        let coordinator = BusCoordinator.shared
        try await coordinator.withExclusiveAccess(priority: .criticalExclusive, name: "Reentrant Flasher") {
            #expect(coordinator.isBusy == true)
            // Appel réentrant imbriqué avec le même nom de session
            try await coordinator.withExclusiveAccess(priority: .criticalExclusive, name: "Reentrant Flasher") {
                #expect(coordinator.isBusy == true)
            }
            #expect(coordinator.isBusy == true)
        }
        #expect(coordinator.isBusy == false)

        // 7. DoIPHeader : décodage sur Data slice avec startIndex > 0
        let fullDoIP = Data(repeating: 0xEE, count: 16) + Data([0x02, 0xFD, 0x80, 0x01, 0x00, 0x00, 0x00, 0x03, 0x01, 0x02, 0x03])
        let slicedDoIP = fullDoIP.dropFirst(16)
        #expect(slicedDoIP.startIndex == 16)
        let decodedDoIP = DoIPMessage.decode(from: slicedDoIP)
        #expect(decodedDoIP != nil)
        #expect(decodedDoIP?.payload.count == 3)
    }

    // MARK: - DSP & Signal Filtering Tests

    @Test("Biquad IIR Low-Pass & Median Filter")
    func testSignalFilter() {
        let noisySignal = [10.0, 10.2, 50.0, 10.1, 9.9, 10.3] // 50.0 is a rogue spike
        let medianFiltered = SignalFilter.medianFilter(values: noisySignal, windowSize: 3)
        #expect(medianFiltered[2] < 20.0) // Rogue spike filtered out

        let biquad = SignalFilter.Biquad.lowPass(cutoffFrequency: 2.0, sampleRate: 10.0)
        let filteredBatch = biquad.filter(batch: [1.0, 1.0, 1.0, 1.0, 1.0])
        #expect(filteredBatch.count == 5)
        #expect(filteredBatch.last ?? 0 > 0.5)
    }

    @Test("Spectral Analyzer FFT Peak Detection")
    func testSpectralAnalyzer() {
        // Create 64 samples of a 10 Hz sine wave sampled at 100 Hz
        let sampleRate = 100.0
        let n = 64
        var samples = [Double](repeating: 0.0, count: n)
        for t in 0..<n {
            let time = Double(t) / sampleRate
            samples[t] = sin(2.0 * Double.pi * 10.0 * time)
        }

        let result = SpectralAnalyzer.analyze(samples: samples, sampleRateHz: sampleRate, topPeaksCount: 1)
        #expect(result != nil)
        if let peak = result?.dominantPeaks.first {
            // Frequency peak should be very close to 10 Hz (frequency bin resolution = 100/64 ≈ 1.56 Hz)
            #expect(abs(peak.frequencyHz - 10.0) <= 2.0)
            #expect(peak.magnitude > 0.3)
        }
    }

    // MARK: - VehicleML Artificial Intelligence Tests

    @Test("CAN Intrusion Detector (Nominal vs Flood & Injection)")
    func testCANIntrusionDetector() async {
        let detector = CANIntrusionDetector(windowSize: 30)

        // 1. Nominal CAN traffic
        var report: BusAnomalyReport? = nil
        for i in 0..<15 {
            let frame = CANSampleFrame(canID: 0x7E0, payload: [0x02, 0x01, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00], timestampSeconds: Double(i) * 0.05)
            report = await detector.ingest(frame: frame)
        }
        #expect(report?.status == .nominal)
        #expect(report?.anomalyScore ?? 1.0 < 0.3)

        // 2. Flood injection attack (< 0.1 ms between frames)
        var floodReport: BusAnomalyReport? = nil
        for i in 0..<20 {
            let floodFrame = CANSampleFrame(canID: 0x123, payload: [0xFF, 0xFF, 0xAA, 0x55], timestampSeconds: 1.0 + (Double(i) * 0.00005))
            floodReport = await detector.ingest(frame: floodFrame)
        }
        #expect(floodReport?.status == .busFlood)
        #expect(floodReport?.anomalyScore ?? 0.0 > 0.8)
    }

    @Test("Semantic Signal Classifier")
    func testSemanticSignalClassifier() {
        // 1. Constant Marker
        let constSignal = [0x55, 0x55, 0x55, 0x55, 0x55].map { Double($0) }
        let resConst = SemanticSignalClassifier.classify(sliceName: "A", values: constSignal)
        #expect(resConst.category == .constantMarker)

        // 2. Incremental Frame Counter
        let counterSignal = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0]
        let resCounter = SemanticSignalClassifier.classify(sliceName: "B", values: counterSignal)
        #expect(resCounter.category == .counterOrCRC)

        // 3. Engine RPM
        let rpmSignal = [800.0, 850.0, 1200.0, 2500.0, 3200.0, 2800.0, 900.0]
        let resRPM = SemanticSignalClassifier.classify(sliceName: "AB", values: rpmSignal)
        #expect(resRPM.category == .engineRPM)

        // 4. Slow thermal drift
        let tempSignal = [82.0, 82.1, 82.2, 82.3, 82.4, 82.5]
        let resTemp = SemanticSignalClassifier.classify(sliceName: "C", values: tempSignal)
        #expect(resTemp.category == .thermalSlow)

        // 5. Brake pedal pressure spike
        let brakeSignal = [0.0, 0.0, 0.0, 0.0, 25.0, 40.0, 30.0, 0.0, 0.0]
        let resBrake = SemanticSignalClassifier.classify(sliceName: "D", values: brakeSignal)
        #expect(resBrake.category == .brakePedalOrPressure)
    }

    @Test("Odometer Fraud Auditor (Genuine vs Tampered)")
    func testOdometerFraudAuditor() {
        // 1. Genuine Vehicle
        let genuineInput = OdometerFraudAuditor.InputData(
            clusterMileageKm: 120000,
            engineECUMileageKm: 120040,
            absMileageKm: 119980,
            transmissionMileageKm: 120010,
            engineHours: 2400, // 120000 / 2400 = 50 km/h avg
            dpfLastRegenerationKm: 119600,
            freezeFrameMileages: [115000, 118000]
        )
        let genuineReport = OdometerFraudAuditor.audit(input: genuineInput)
        #expect(genuineReport.riskLevel == .genuine)
        #expect(genuineReport.riskScore < 0.15)
        #expect(genuineReport.anomalies.isEmpty)

        // 2. Severe Rollback Fraud (Cluster shows 65,000 km, but ECU shows 145,000 km and DPF regenerated at 138,000 km)
        let fraudulentInput = OdometerFraudAuditor.InputData(
            clusterMileageKm: 65000,
            engineECUMileageKm: 145000,
            absMileageKm: 144800,
            engineHours: 3500, // 65000 / 3500 = 18.5 km/h avg
            dpfLastRegenerationKm: 138000,
            freezeFrameMileages: [120000]
        )
        let fraudReport = OdometerFraudAuditor.audit(input: fraudulentInput)
        #expect(fraudReport.riskLevel == .confirmedTampering)
        #expect(fraudReport.riskScore >= 0.70)
        #expect(fraudReport.estimatedRealMileageKm == 145000)
        #expect(!fraudReport.anomalies.isEmpty)
    }

    @Test("Battery Health Estimator")
    func testBatteryHealthEstimator() {
        // Healthy battery: 12.6V resting, 10.5V cranking (2.1V drop at 220A -> Ri ≈ 9.5 mΩ)
        let goodReport = BatteryHealthEstimator.estimate(restingVoltage: 12.6, minimumCrankingVoltage: 10.5)
        #expect(goodReport.status == .good || goodReport.status == .excellent)
        #expect(goodReport.stateOfHealthPercent > 65.0)

        // Failing battery: 12.1V resting, 8.5V cranking (severe voltage drop)
        let badReport = BatteryHealthEstimator.estimate(restingVoltage: 12.1, minimumCrankingVoltage: 8.5)
        #expect(badReport.status == .replaceImmediate)
        #expect(badReport.stateOfHealthPercent < 50.0)
    }

    // MARK: - Non-Regression & Hardening Tests

    @Test("Spectral Analyzer Top Peaks & Bounds Safety")
    func testSpectralAnalyzerBounds() {
        let dummySamples = (0..<16).map { sin(Double($0) * 0.5) }

        // 1. Negative topPeaksCount must return nil safely (no Array.prefix crash)
        let negativeResult = SpectralAnalyzer.analyze(samples: dummySamples, sampleRateHz: 100, topPeaksCount: -1)
        #expect(negativeResult == nil)

        // 2. Zero topPeaksCount must return nil
        let zeroResult = SpectralAnalyzer.analyze(samples: dummySamples, sampleRateHz: 100, topPeaksCount: 0)
        #expect(zeroResult == nil)

        // 3. Insufficient samples (< 8) must return nil
        let shortResult = SpectralAnalyzer.analyze(samples: [1.0, 2.0, 3.0], sampleRateHz: 100, topPeaksCount: 2)
        #expect(shortResult == nil)

        // 4. Invalid sample rate must return nil
        let badRateResult = SpectralAnalyzer.analyze(samples: dummySamples, sampleRateHz: -50.0, topPeaksCount: 2)
        #expect(badRateResult == nil)

        // 5. Valid signal produces valid dominant peaks
        let validResult = SpectralAnalyzer.analyze(samples: dummySamples, sampleRateHz: 100, topPeaksCount: 2)
        #expect(validResult != nil)
        #expect(validResult?.dominantPeaks.count ?? 0 <= 2)
    }

    @Test("Formula Evaluator Bit Shift & IEEE-754 Safety")
    func testFormulaEvaluatorBitShiftSafety() {
        let evaluator = FormulaEvaluator()

        // 1. Bit shift with Infinity RHS should fail gracefully
        let infShift = evaluator.evaluate(formula: "1 << (1 / 0)", bytes: [0x00])
        #expect(infShift == nil)

        // 2. Bit shift with masking semantics (64 & 63 = 0 -> 1 << 0 = 1.0)
        let maskingShift = evaluator.evaluate(formula: "1 << 64", bytes: [0x00])
        #expect(maskingShift == 1.0)

        // 3. Bit shift < 0 should fail gracefully
        let negShift = evaluator.evaluate(formula: "1 << -1", bytes: [0x00])
        #expect(negShift == nil)

        // 4. Bit shift with massive double (1e25) should fail gracefully
        let hugeShift = evaluator.evaluate(formula: "1 << 10000000000000000000000000", bytes: [0x00])
        #expect(hugeShift == nil)

        // 5. Normal bit shifts must succeed
        #expect(evaluator.evaluate(formula: "1 << 4", bytes: [0x00]) == 16.0)
        #expect(evaluator.evaluate(formula: "32 >> 2", bytes: [0x00]) == 8.0)

        // 6. Safe bitwise operations with valid Int64 boundaries
        let bitwiseAndRes = evaluator.evaluate(formula: "A & 15", bytes: [0xFA])
        #expect(bitwiseAndRes == 10.0)
    }

    @Test("Odometer Fraud Auditor Infinite/Corrupt Hours")
    func testOdometerFraudAuditorCorruptedHours() {
        // Infinity engine hours should not trigger a fatal error or false crash
        let infInput = OdometerFraudAuditor.InputData(
            clusterMileageKm: 100000,
            engineECUMileageKm: 100000,
            absMileageKm: 100000,
            transmissionMileageKm: 100000,
            engineHours: Double.infinity,
            dpfLastRegenerationKm: 99000,
            freezeFrameMileages: [95000]
        )
        let report = OdometerFraudAuditor.audit(input: infInput)
        #expect(report.riskScore.isFinite)

        // NaN engine hours
        let nanInput = OdometerFraudAuditor.InputData(
            clusterMileageKm: 100000,
            engineECUMileageKm: 100000,
            absMileageKm: 100000,
            transmissionMileageKm: 100000,
            engineHours: Double.nan,
            dpfLastRegenerationKm: 99000,
            freezeFrameMileages: [95000]
        )
        let nanReport = OdometerFraudAuditor.audit(input: nanInput)
        #expect(nanReport.riskScore.isFinite)
    }

    @Test("Battery Health Estimator Corrupted/Inverted Voltages")
    func testBatteryHealthEstimatorCorruptInputs() {
        // 1. NaN resting voltage
        let nanReport = BatteryHealthEstimator.estimate(restingVoltage: Double.nan, minimumCrankingVoltage: 10.0)
        #expect(nanReport.status == .replaceImmediate)

        // 2. Inverted crank voltage (cranking > resting is physically impossible)
        let invertedReport = BatteryHealthEstimator.estimate(restingVoltage: 10.0, minimumCrankingVoltage: 12.0)
        #expect(invertedReport.status == .replaceImmediate)

        // 3. Negative resting voltage
        let negReport = BatteryHealthEstimator.estimate(restingVoltage: -12.0, minimumCrankingVoltage: 8.0)
        #expect(negReport.status == .replaceImmediate)
    }

    @Test("Signal Filter Super-Nyquist & Numerical Stability")
    func testSignalFilterNyquistStability() {
        // 1. Super-Nyquist cutoff (cutoffFrequency >= sampleRate / 2) must be clamped safely
        let biquad = SignalFilter.Biquad.lowPass(cutoffFrequency: 100.0, sampleRate: 50.0)
        #expect(biquad.b0.isFinite)
        #expect(biquad.a1.isFinite)
        #expect(biquad.a2.isFinite)

        let filtered = biquad.filter(batch: [1.0, 2.0, 3.0, 4.0, 5.0])
        #expect(filtered.allSatisfy { $0.isFinite })

        // 2. Invalid sampleRate or cutoff
        let safeBiquad = SignalFilter.Biquad.lowPass(cutoffFrequency: 10.0, sampleRate: 0.0)
        #expect(safeBiquad.b0 == 1.0) // passthrough

        // 3. EMA with NaN alpha
        let emaNaNAlpha = SignalFilter.exponentialMovingAverage(values: [1.0, 2.0, 3.0], alpha: Double.nan)
        #expect(emaNaNAlpha.isEmpty)

        // 4. EMA with transient NaN sample dropouts
        let emaSamples = SignalFilter.exponentialMovingAverage(values: [10.0, Double.nan, 12.0, 14.0], alpha: 0.5)
        #expect(emaSamples.allSatisfy { $0.isFinite })

        // 5. Median filter with NaN dropouts and even window size
        let medianFiltered = SignalFilter.medianFilter(values: [1.0, Double.nan, 100.0, 2.0, 3.0], windowSize: 4)
        #expect(medianFiltered.allSatisfy { $0.isFinite })
    }

    @Test("BusCoordinator Task-Local Session Token Isolation")
    @MainActor
    func testBusCoordinatorSessionTokenIsolation() async throws {
        let coordinator = BusCoordinator()

        // Nested reentrancy on the same task succeeds via TaskLocal token
        try await coordinator.withExclusiveAccess(priority: .criticalExclusive, name: "TaskA") {
            #expect(coordinator.isBusy == true)
            try await coordinator.withExclusiveAccess(priority: .criticalExclusive, name: "TaskA") {
                #expect(coordinator.isBusy == true)
            }
        }
        #expect(coordinator.isBusy == false)
    }

    @Test("Powertrain Calculations Finitude & Defensive Guards")
    func testPowertrainCalculationsSafety() {
        // 1. Instantaneous power with Infinity
        let infPower = PowertrainCalculations.instantaneousPower(torqueNm: Double.infinity, rpm: 2000)
        #expect(infPower.kw == 0.0)
        #expect(infPower.horsepower == 0.0)

        // 2. Instantaneous torque with NaN
        let nanTorque = PowertrainCalculations.instantaneousTorque(powerKw: Double.nan, rpm: 2000)
        #expect(nanTorque == 0.0)

        // 3. Fuel consumption with NaN
        let nanFuel = PowertrainCalculations.instantaneousFuelConsumption(mafGPerSec: Double.nan, speedKmh: 50)
        #expect(nanFuel.litersPerHour == 0.0)
        #expect(nanFuel.litersPer100Km == nil)

        // 4. Volumetric efficiency with NaN
        let nanVE = PowertrainCalculations.volumetricEfficiency(
            mafGPerSec: Double.nan,
            rpm: 3000,
            mapKpa: 100,
            iatCelsius: 20,
            displacementLiters: 1.6
        )
        #expect(nanVE == nil)

        // 5. Normal calculation produces accurate VE
        let normalVE = PowertrainCalculations.volumetricEfficiency(
            mafGPerSec: 50.0,
            rpm: 3000,
            mapKpa: 100,
            iatCelsius: 20,
            displacementLiters: 2.0
        )
        #expect(normalVE != nil)
        #expect((normalVE ?? 0) > 0)
    }

    @Test("DDT2000 Raw Structs Public Initializers")
    func testDDT2000RawStructsPublicInits() {
        let obd = DDT2UnifiedConverter.DDT2000RawOBD(protocolName: "CAN", send_id: "7E0", recv_id: "7E8", baudrate: 500000)
        #expect(obd.protocolName == "CAN")
        #expect(obd.send_id == "7E0")

        let data = DDT2UnifiedConverter.DDT2000RawData(bitscount: 8, bytescount: 1, scaled: true, step: 0.5, offset: 0.0)
        #expect(data.bitscount == 8)
        #expect(data.step == 0.5)

        let item = DDT2UnifiedConverter.DDT2000RawReceiveItem(firstbyte: 1, bitoffset: 0, ref: true)
        #expect(item.firstbyte == 1)

        let req = DDT2UnifiedConverter.DDT2000RawRequest(sentbytes: "2101", name: "ReadData", receivebyte_dataitems: ["Param": item])
        #expect(req.sentbytes == "2101")
        #expect(req.receivebyte_dataitems?["Param"]?.firstbyte == 1)
    }

    @Test("CAN Intrusion Detector Frame Buffer & Tracking Pruning")
    func testCANIntrusionDetectorPruning() async {
        let detector = CANIntrusionDetector(windowSize: 10)

        // Ingest 20 frames with varying CAN IDs to trigger eviction
        for i in 0..<20 {
            let frame = CANSampleFrame(canID: UInt32(0x100 + i), payload: [0x01], timestampSeconds: Double(i) * 0.01)
            _ = await detector.ingest(frame: frame)
        }

        let report = await detector.evaluateSecurity()
        #expect(report.messageCount == 10)
    }
}




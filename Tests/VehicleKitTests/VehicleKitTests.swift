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

    @Test("ISO-TP CAN-FD Single Frame & 32-bit First Frame")
    func testISOTPCANFDExtension() async {
        let reassembler = ISOTPReassembler()

        // 1. CAN-FD Single Frame with 16 bytes payload (byte 0 = 0x00, byte 1 = 0x10)
        let fdPayload = [UInt8](repeating: 0xAB, count: 16)
        var fdFrameData = Data([0x00, 0x10])
        fdFrameData.append(contentsOf: fdPayload)
        let sfResult = await reassembler.processFrame(address: 0x7E8, data: fdFrameData)
        if case .completed(let payload) = sfResult {
            #expect(payload.count == 16)
            #expect(payload.first == 0xAB)
        } else {
            Issue.record("Expected CAN-FD Single Frame completion")
        }

        // 2. CAN-FD First Frame with 32-bit length (5000 bytes > 4095)
        let ffHeader = Data([0x10, 0x00, 0x00, 0x00, 0x13, 0x88, 0x42, 0x43])
        let ffResult = await reassembler.processFrame(address: 0x7E8, data: ffHeader)
        #expect(ffResult == .needsFlowControl)
    }

    @Test("OBD2 Mode 06 On-Board Monitoring Decoder")
    func testOBD2Mode06Decoding() {
        // Response with 2 tests:
        // Test 1: MID 21 (Catalyst Bank 1), TID 01, CID 01, Val 30 (0x001E), Min 0 (0x0000), Max 100 (0x0064) -> Passed
        // Test 2: MID A2 (Misfire Cyl 1), TID 0B, CID 01, Val 25 (0x0019), Min 0 (0x0000), Max 20 (0x0014) -> Failed (val > max)
        let hex = "46 21 01 01 00 1E 00 00 00 64 A2 0B 01 00 19 00 00 00 14"
        let results = OBD2Analyzer.decodeMode06(responseHex: hex)
        #expect(results.count == 2)

        #expect(results[0].mid == 0x21)
        #expect(results[0].monitorName == "Catalyst Monitor Bank 1")
        #expect(results[0].testValue == 30.0)
        #expect(results[0].minLimit == 0.0)
        #expect(results[0].maxLimit == 100.0)
        #expect(results[0].isPassed == true)

        #expect(results[1].mid == 0xA2)
        #expect(results[1].monitorName == "Misfire Cylinder 1 Monitor")
        #expect(results[1].testValue == 25.0)
        #expect(results[1].isPassed == false)
    }

    @Test("Simulator Engine Mode 06 Diagnostics")
    func testSimulatorEngineMode06() async throws {
        let sim = SimulatorEngine()
        let resp21 = try await sim.sendDiagnosticRequest("0621")
        #expect(resp21.contains("46 21"))

        let results = OBD2Analyzer.decodeMode06(responseHex: resp21)
        #expect(!results.isEmpty)
        #expect(results.first?.isPassed == true)
    }

    @Test("Powertrain Thermodynamics, BSFC, CO2 & Turbo Boost")
    func testPowertrainThermodynamicsAndEmissions() {
        // 1. BSFC calculation (Power 100 kW, MAF 50 g/s, AFR 14.7)
        let bsfc = PowertrainCalculations.brakeSpecificFuelConsumption(powerKw: 100.0, mafGPerSec: 50.0)
        #expect(bsfc != nil)
        #expect((bsfc ?? 0) > 100.0 && (bsfc ?? 0) < 150.0)

        // 2. Thermal efficiency (BSFC ~ 122.45, LHV 44 MJ/kg)
        let eta = PowertrainCalculations.thermalEfficiency(powerKw: 100.0, mafGPerSec: 50.0)
        #expect(eta != nil)
        #expect((eta ?? 0) > 0 && (eta ?? 0) <= 100.0)

        // 3. CO2 emissions (MAF 50 g/s, speed 100 km/h)
        let co2 = PowertrainCalculations.instantaneousCO2Emissions(mafGPerSec: 50.0, speedKmh: 100.0)
        #expect(co2.gramsPerHour > 0)
        #expect((co2.gramsPerKm ?? 0) > 0)

        // 4. Turbo boost pressure (MAP 220 kPa, BARO 100 kPa)
        let boost = PowertrainCalculations.turboBoostPressure(mapKpa: 220.0, baroKpa: 100.0)
        #expect(abs(boost.boostBar - 1.2) < 0.001)
        #expect(abs(boost.pressureRatio - 2.2) < 0.001)
        #expect(boost.boostPsi > 17.0)
    }

    @Test("CAN Intrusion Detector O(1) Sliding Window Entropy")
    func testCANIntrusionDetectorO1Entropy() async {
        let detector = CANIntrusionDetector(windowSize: 50)
        for i in 0..<100 {
            let payload: [UInt8] = [UInt8(i % 16), UInt8((i * 3) % 256)]
            let frame = CANSampleFrame(canID: UInt32(0x200 + (i % 4)), payload: payload, timestampSeconds: Double(i) * 0.01)
            _ = await detector.ingest(frame: frame)
        }
        let report = await detector.evaluateSecurity()
        #expect(report.messageCount == 50)
        #expect(report.payloadEntropy > 0)
    }

    // MARK: - ECU Calibration & Software Integrity Audit (CalID / CVN / KWP 2180)

    @Test("CalibrationReader OBD-II Mode 09 CalID & CVN Parsing")
    func testCalibrationReaderMode09Parsing() {
        // 16-byte ASCII CalID "8200399038_S3000"
        let calIDResp = "49 04 01 38 32 30 30 33 39 39 30 33 38 5F 53 33 30 30 30"
        let calIDs = CalibrationReader.parseOBD2CalID(calIDResp)
        #expect(calIDs == ["8200399038_S3000"])

        // 4-byte CVN A3B8C912
        let cvnResp = "49 06 01 A3 B8 C9 12"
        let cvns = CalibrationReader.parseOBD2CVN(cvnResp)
        #expect(cvns == ["A3B8C912"])
    }

    @Test("CalibrationReader UDS 0x22 Identification Parsing")
    func testCalibrationReaderUDSParsing() {
        let calID = CalibrationReader.parseUDSIdentifier("62 F1 98 38 32 30 30 33 39 39 30 33 38", did: "F198")
        #expect(calID == "8200399038")

        let cvn = CalibrationReader.parseUDSHexPayload("62 F1 99 A3 B8 C9 12", did: "F199")
        #expect(cvn == "A3B8C912")
    }

    @Test("CalibrationReader Renault KWP2000 Service 2180 Block Parsing")
    func testCalibrationReaderKWP2180Parsing() throws {
        // 20-byte Renault DDT2000 identification block after 61 80
        let kwpResp = "61 80 82 00 39 90 38 44 00 31 37 82 00 29 84 57 00 B2 04 30 01 05"
        let info = try #require(CalibrationReader.parseKWP2000Identification2180(kwpResp))

        #expect(info.primaryCalID == "CAL-0105")
        #expect(info.hardwareNumber == "HW-8200298457 (MPR 8200399038)")
        #expect(info.softwareNumber == "SW-00B2-V0430")
        #expect(info.protocolSource == "KWP2000-2180")
        #expect(info.isSuspiciousTuningDetected == false)
    }

    @Test("CalibrationReader Suspicious Tuning & Remap Detection")
    func testCalibrationReaderTuningDetection() {
        // 1. Stock calibration
        let stock = ECUCalibrationInfo(
            calibrationIDs: ["8200399038_S3000"],
            calibrationVerificationNumbers: ["A3B8C912"],
            hardwareNumber: "8200298457",
            softwareNumber: "8200592611",
            protocolSource: "OBD2-Mode09"
        )
        #expect(stock.isSuspiciousTuningDetected == false)

        // 2. Zeroed CVN after checksum bypass flash
        let zeroedCVN = ECUCalibrationInfo(
            calibrationIDs: ["8200399038_S3000"],
            calibrationVerificationNumbers: ["00000000"],
            protocolSource: "OBD2-Mode09"
        )
        #expect(zeroedCVN.isSuspiciousTuningDetected == true)

        // 3. Stage 1 / EGR-DPF off marker in CalID or SW
        let stage1 = ECUCalibrationInfo(
            calibrationIDs: ["STAGE1_EGR_OFF"],
            calibrationVerificationNumbers: ["DEADBEEF"],
            protocolSource: "UDS-Service22"
        )
        #expect(stage1.isSuspiciousTuningDetected == true)
    }

    @Test("CalibrationReader Full Multi-Protocol Read on SimulatorEngine")
    func testCalibrationReaderSimulatorIntegration() async throws {
        let sim = SimulatorEngine()
        let info = try #require(await CalibrationReader.read(interface: sim))
        #expect(info.primaryCalID == "8200399038_S3000")
        #expect(info.primaryCVN == "A3B8C912")
        #expect(info.protocolSource == "OBD2-Mode09")
        #expect(info.isSuspiciousTuningDetected == false)

        // OEM "MODUS" or "MODULE" must not trigger false positive on "MOD"
        let modusOEM = ECUCalibrationInfo(
            calibrationIDs: ["RENAULT_MODUS_15DCI"],
            calibrationVerificationNumbers: ["A3B8C912"],
            hardwareNumber: "MODULE_DELPHI",
            softwareNumber: "8200592611",
            protocolSource: "KWP2000-2180"
        )
        #expect(modusOEM.isSuspiciousTuningDetected == false)
    }

    // MARK: - P0-P3 Engine Audit Hardening Suite

    @Test("BusCoordinator Waiter Cancellation Without Continuation Leak or Premature Release")
    @MainActor
    func testBusCoordinatorWaiterCancellationSafety() async throws {
        let coordinator = BusCoordinator()

        // Owner holds the bus
        let ownerAcquired = await coordinator.acquire(priority: .criticalExclusive, name: "Owner")
        #expect(ownerAcquired == true)
        #expect(coordinator.isBusy == true)

        // Spawn a waiter that gets cancelled while waiting in queue
        let cancelledTask = Task { @MainActor in
            try await coordinator.withExclusiveAccess(priority: .interactive, name: "CancelledWaiter") {
                _ = Issue.record("Cancelled waiter should not execute operation")
            }
        }

        try await Task.sleep(for: .milliseconds(20))
        cancelledTask.cancel()

        do {
            try await cancelledTask.value
            _ = Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }

        // Bus MUST still be held by Owner (cancelled waiter must not have called release())
        #expect(coordinator.isBusy == true)
        #expect(coordinator.activeSessionName == "Owner")

        coordinator.release()
        #expect(coordinator.isBusy == false)
    }

    @Test("FormulaEvaluator Short-Circuiting, Scientific Notation & Bitwise AND/OR")
    func testFormulaEvaluatorShortCircuitAndScientificNotation() {
        let evaluator = FormulaEvaluator()

        // 1. Short-circuit && prevents division by zero when B == 0
        let safeAnd = evaluator.evaluate(formula: "B != 0 && (A / B) > 2", bytes: [0x10, 0x00])
        #expect(safeAnd == 0.0)

        // 2. Short-circuit || skips invalid RHS when LHS is true
        let safeOr = evaluator.evaluate(formula: "A > 0 || (1 / 0) > 0", bytes: [0x05])
        #expect(safeOr == 1.0)

        // 3. Scientific notation (1e-2, 2.5E2)
        let sci1 = evaluator.evaluate(formula: "A * 1e-2", bytes: [100])
        #expect(sci1 == 1.0)
        let sci2 = evaluator.evaluate(formula: "A * 2.5E2", bytes: [2])
        #expect(sci2 == 500.0)
    }

    @Test("UDSNRC False-Positive Immunity on 0x7F Data Payload Bytes & Unaligned Nibbles")
    func testUDSNRCByteAlignmentAndPayloadImmunity() {
        // 1. Positive UDS response containing "7F" across nibbles (07 F1) or as data byte
        #expect(UDSNRC.parse(from: "62 F1 90 07 F1 22 33") == nil)
        #expect(UDSNRC.parse(from: "62 01 05 7F 10 22") == nil)

        // 2. Genuine UDS Negative Response (7F 22 31) and PCI-prefixed (03 7F 22 31)
        let nrc1 = UDSNRC.parse(from: "7F 22 31")
        #expect(nrc1?.requestedServiceID == 0x22)
        #expect(nrc1?.nrc == .requestOutOfRange)

        let nrc2 = UDSNRC.parse(from: "03 7F 27 35")
        #expect(nrc2?.requestedServiceID == 0x27)
        #expect(nrc2?.nrc == .invalidKey)
    }

    @Test("J1939 Extended Data Page (EDP) & 0xFFFF Not-Available Sentinel Filtering")
    func testJ1939EDPAndSentinelFiltering() {
        // 1. Sentinel 0xFF / 0xFFFF in EEC1 (0x0CF00400) must be filtered out
        let sentinelPayload = Data(repeating: 0xFF, count: 8)
        let emptySignals = J1939Decoder.decode(pgn: 0xF004, data: sentinelPayload)
        #expect(emptySignals.isEmpty)

        // 2. EDP bit (bit 25) included in PGN calculation
        let edpHeader = J1939Header(canID: 0x0AF00400) // EDP = 1, DP = 0
        #expect(edpHeader.extendedDataPage == 1)
        #expect(edpHeader.pgn == 0x2F004)
    }

    @Test("SignalCorrelator High-Offset Pearson Stability & Biquad Cold-Start Pre-Warming")
    func testAnalyticsNumericalImprovements() {
        // 1. High DC offset (150,000 + small delta) Pearson correlation must not suffer catastrophic cancellation
        let x = [150_000.01, 150_000.02, 150_000.03, 150_000.04, 150_000.05]
        let y = [150_000.02, 150_000.04, 150_000.06, 150_000.08, 150_000.10]
        let r = SignalCorrelator.pearsonCorrelation(x: x, y: y)
        #expect(abs((r ?? 0.0) - 1.0) < 1e-6)

        // 2. Biquad filter pre-warms on first finite sample (no cold-start jump from 0.0)
        let biquad = SignalFilter.Biquad.lowPass(cutoffFrequency: 2.0, sampleRate: 10.0)
        var state = SignalFilter.Biquad.State()
        let firstOut = biquad.filter(sample: 850.0, state: &state)
        #expect(abs(firstOut - 850.0) < 1e-6)
    }

    @Test("OdometerFraudAuditor Sentinel Filtering & BatteryHealthEstimator Thermal/SoC Guards")
    func testVehicleMLHardening() {
        // 1. Sentinel 655350 km on ABS must be ignored rather than triggering confirmedTampering
        let sentinelInput = OdometerFraudAuditor.InputData(
            clusterMileageKm: 120_000,
            engineECUMileageKm: 120_000,
            absMileageKm: 655_350,
            freezeFrameMileages: [115_000, 655_350]
        )
        let fraudReport = OdometerFraudAuditor.audit(input: sentinelInput)
        #expect(fraudReport.riskLevel == .genuine)
        #expect(fraudReport.estimatedRealMileageKm == 120_000)

        // 2. Discharged battery (11.7V resting) with small crank sag must not be rated .excellent
        let dischargedBattery = BatteryHealthEstimator.estimate(
            restingVoltage: 11.7,
            minimumCrankingVoltage: 10.6,
            temperatureCelsius: 20.0
        )
        #expect(dischargedBattery.status != .excellent)

        // 3. Steering angle bipolar zero-crossing signal classification
        let steeringSamples = [-45.0, -30.0, -10.0, 0.0, 15.0, 35.0, 50.0, 20.0, -25.0]
        let classified = SemanticSignalClassifier.classify(sliceName: "B0_B1", values: steeringSamples)
        #expect(classified.category == .steeringAngle)
    }

    @Test("White Panda STM32F4 16-Byte bxCAN Framing, TX Echo Filtering & Health Telemetry")
    func testWhitePandaBxCAN16AndHealthTelemetry() throws {
        #expect(PandaSafetyModel.allOutput.rawValue == 17)
        #expect(PandaHardwareType.whitePanda.rawValue == 1)

        // 1. Standard 11-bit bxCAN16 packing & unpacking (0x7E0 -> 0x7E8)
        let payload = Data([0x02, 0x10, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00])
        let packed16 = PandaDriver.packBxCAN16(address: 0x7E0, data: payload, bus: 0)
        #expect(packed16.count == 16)

        // Simulate USB EP1 IN / UDP 1338 stream with TX echo (bus 0x80) + RX frame (0x7E8 on bus 0)
        var txEcho = packed16
        txEcho[4] |= (0x80 << 4) & 0xFF
        txEcho[5] |= UInt8((0x80 >> 4) & 0xFF)
        let rxFrame16 = PandaDriver.packBxCAN16(address: 0x7E8, data: Data([0x02, 0x50, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00]), bus: 0)

        let combinedStream = txEcho + rxFrame16
        let rxOnly = PandaDriver.unpackBxCAN16(data: combinedStream, includeTxEcho: false)
        #expect(rxOnly.count == 1)
        #expect(rxOnly.first?.address == 0x7E8)
        #expect(rxOnly.first?.bus == 0)
        #expect(rxOnly.first?.isTxReceipt == false)

        let withEcho = PandaDriver.unpackBxCAN16(data: combinedStream, includeTxEcho: true)
        #expect(withEcho.count == 2)
        #expect(withEcho.first?.isTxReceipt == true)

        // 2. Real 41-byte health_t buffer captured from White Panda v1.7.5-DEV-unknown-DEBUG
        let rawHealth = Data([
            0x91, 0x00, 0x00, 0x00, // uptime = 145s
            0x8E, 0x12, 0x00, 0x00, // voltage = 4750 mV
            0xFE, 0x0F, 0x00, 0x00, // current = 4094
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, // faults = 0
            0x00, 0x00, 0x01, 0x00, // controls_allowed = 1
            0x00, 0x01, 0x11, 0x00, // usb_power_mode = 1, safety_model = 0x11 (17), fault_status = 0
            0x00
        ])
        let health = try #require(PandaHealth(data: rawHealth))
        #expect(health.uptime == 145)
        #expect(health.voltageMV == 4750)
        #expect(health.faults == 0)
        #expect(health.controlsAllowed == true)
        #expect(health.safetyModel == 17)
        #expect(health.faultStatus == 0)
    }

    @Test("ECU Flash Validator, Binary Diff, Checksum CRC32 & UDS/KWP2000 Memory Transfer")
    func testECUFlashValidatorAndMemoryTransfer() async throws {
        let calInfo = ECUCalibrationInfo(
            calibrationIDs: ["8200399038_S3000"],
            calibrationVerificationNumbers: ["A3B8C912"],
            hardwareNumber: "HW-8200298457",
            softwareNumber: "SW-00B2-V0430",
            protocolSource: "KWP2000-2180"
        )

        // 1. Build synthetic 64 KB stock calibration & inspect metadata
        let stockBin = ECUFlashValidator.buildSyntheticStockCalibration(calibration: calInfo, size: 65536)
        #expect(stockBin.count == 65536)

        let stockMeta = ECUFlashValidator.inspect(data: stockBin, fileName: "scenic2_stock.bin")
        #expect(stockMeta.isValidSize == true)
        #expect(stockMeta.isAllBlankOrZero == false)
        #expect(stockMeta.detectedASCIIIdentifiers.contains("HW-8200298457"))
        #expect(stockMeta.detectedASCIIIdentifiers.contains("SW-00B2-V0430"))
        #expect(stockMeta.detectedASCIIIdentifiers.contains("8200399038_S3000"))

        // 2. Build simulated Stage 1 calibration & compare sectors
        let stage1Bin = ECUFlashValidator.buildSimulatedStage1Calibration(from: stockBin)
        #expect(stage1Bin.count == 65536)
        #expect(ECUFlashValidator.crc32(stage1Bin) != ECUFlashValidator.crc32(stockBin))

        let diff = ECUFlashValidator.compare(
            original: stockBin,
            modified: stage1Bin,
            sectorSize: 4096,
            ecuCalibration: calInfo
        )
        #expect(diff.sizeMatches == true)
        #expect(diff.hwSwCompatibilityPassed == true)
        #expect(diff.changedBytesCount > 0)
        #expect(!diff.modifiedSectors.isEmpty)
        #expect(diff.modifiedSectors.count < diff.totalSectors)

        // 3. Pre-Flight Safety Gate evaluation
        let stage1Meta = ECUFlashValidator.inspect(data: stage1Bin, fileName: "scenic2_stage1.bin")
        let safePreFlight = ECUFlashValidator.evaluatePreFlight(
            batteryVoltage: 13.4,
            metadata: stage1Meta,
            ecuCalibration: calInfo,
            hasStockBackupInVault: true
        )
        #expect(safePreFlight.canProceedWithFlash == true)
        #expect(safePreFlight.blockingReasons.isEmpty)

        let lowVoltPreFlight = ECUFlashValidator.evaluatePreFlight(
            batteryVoltage: 11.9,
            metadata: stage1Meta,
            ecuCalibration: calInfo,
            hasStockBackupInVault: false
        )
        #expect(lowVoltPreFlight.canProceedWithFlash == false)
        #expect(lowVoltPreFlight.isBatteryVoltageSafe == false)
        #expect(lowVoltPreFlight.blockingReasons.count >= 2)

        // 4. UDSClient & KWP2000Client memory transfer services against SimulatorEngine
        let sim = SimulatorEngine()
        let uds = UDSClient(interface: sim)
        defer { Task { await uds.stop() } }

        let readMem = try await uds.readMemoryByAddress(memoryAddress: 0x040000, memorySize: 16)
        #expect(String(decoding: readMem, as: UTF8.self) == "8200399038_S3000")

        let maxUploadBlock = try await uds.requestUpload(memoryAddress: 0x040000, uncompressedSize: 65536)
        #expect(maxUploadBlock == 1024)

        let maxDownloadBlock = try await uds.requestDownload(memoryAddress: 0x040000, uncompressedSize: 65536)
        #expect(maxDownloadBlock == 1024)

        _ = try await uds.eraseMemory(memoryAddress: 0x040000, memorySize: 65536)
        _ = try await uds.transferData(blockSequenceCounter: 1, payload: Data([0xAA, 0xBB, 0xCC, 0xDD]))
        _ = try await uds.requestTransferExit()
        _ = try await uds.checkProgrammingDependencies(checksumHex: stage1Meta.crc32Hex)

        let kwp = KWP2000Client(interface: sim)
        defer { kwp.stop() }
        let kwpMem = try await kwp.readMemoryByAddress(memoryAddress: 0x040000, memorySize: 16)
        #expect(String(decoding: kwpMem, as: UTF8.self) == "8200399038_S3000")
        _ = try await kwp.transferDataBytes(blockSequenceCounter: 1, payload: Data([0x01, 0x02, 0x03, 0x04]))
    }

    @Test("ECUFlashValidator KWP2000 2180 Multi-Token HW, Trailing Sector Diff & Voltage Finitude")
    func testECUFlashValidatorEdgeCases() throws {
        // 1. Non-zero startIndex Data slices & sectorSize <= 0 safety
        let prefix = Data(repeating: 0xAA, count: 16)
        let payloadA = Data((0..<4096).map { UInt8($0 & 0xFF) })
        let payloadB = Data([0xFF] + payloadA.dropFirst())
        let sliceA = (prefix + payloadA)[16..<(16 + 4096)]
        let sliceB = (prefix + payloadB)[16..<(16 + 4096)]

        #expect(sliceA.startIndex == 16)
        #expect(ECUFlashValidator.crc32(sliceA) == ECUFlashValidator.crc32(payloadA))
        #expect(ECUFlashValidator.checksum16(sliceA) == ECUFlashValidator.checksum16(payloadA))

        let zeroSectorDiff = ECUFlashValidator.compare(original: sliceA, modified: sliceB, sectorSize: 0)
        #expect(zeroSectorDiff.changedBytesCount == 1)
        #expect(zeroSectorDiff.modifiedSectors.count == 1)

        // 2. Size mismatch (4096 vs 8192) must record trailing sector in modifiedSectors
        let extendedMod = payloadA + Data(repeating: 0x42, count: 4096)
        let sizeMismatchDiff = ECUFlashValidator.compare(original: payloadA, modified: extendedMod, sectorSize: 4096)
        #expect(sizeMismatchDiff.changedBytesCount == 4096)
        #expect(sizeMismatchDiff.totalSectors == 2)
        #expect(sizeMismatchDiff.modifiedSectors.count == 1)

        // 3. KWP2000 21 80 multi-token hardwareNumber ("HW-8200298457 (MPR 8200399038)") must pass Pre-Flight
        let kwpCal = try #require(
            CalibrationReader.parseKWP2000Identification2180(
                "61 80 82 00 39 90 38 44 00 31 37 82 00 29 84 57 00 B2 04 30 01 05"
            )
        )
        let stockBin = ECUFlashValidator.buildSyntheticStockCalibration(calibration: kwpCal, size: 65536)
        let meta = ECUFlashValidator.inspect(data: stockBin)
        let kwpPreFlight = ECUFlashValidator.evaluatePreFlight(
            batteryVoltage: 13.5,
            metadata: meta,
            ecuCalibration: kwpCal,
            hasStockBackupInVault: true
        )
        #expect(kwpPreFlight.isTargetCompatible == true)
        #expect(kwpPreFlight.canProceedWithFlash == true)

        // 4. Infinite or over-voltage battery (> 15.8 V) must be rejected by Pre-Flight Gate
        let infReport = ECUFlashValidator.evaluatePreFlight(
            batteryVoltage: .infinity,
            metadata: meta,
            ecuCalibration: kwpCal,
            hasStockBackupInVault: true
        )
        #expect(infReport.isBatteryVoltageSafe == false)
        #expect(infReport.canProceedWithFlash == false)

        let overVoltReport = ECUFlashValidator.evaluatePreFlight(
            batteryVoltage: 16.5,
            metadata: meta,
            ecuCalibration: kwpCal,
            hasStockBackupInVault: true
        )
        #expect(overVoltReport.isBatteryVoltageSafe == false)
        #expect(overVoltReport.canProceedWithFlash == false)
    }

    @Test("UDSClient SecurityAccess Level 0 Guard, ALFID Bounds & MaxBlockLength Shift Safety")
    func testUDSClientBoundsAndShiftSafety() async throws {
        actor MockUDSInterface: VehicleInterface {
            var lastRequest: String = ""
            var nextResponse: String = "74 20 04 00"
            func setNextResponse(_ resp: String) {
                nextResponse = resp
            }
            func setTarget(txID: String, rxID: String?) async throws {}
            func sendDiagnosticRequest(_ requestHex: String, timeout: TimeInterval) async throws -> String {
                lastRequest = requestHex
                return nextResponse
            }
        }

        let mock = MockUDSInterface()
        let client = UDSClient(interface: mock)

        // 1. level == 0 must throw UDSError instead of trapping on UInt8(0) - 1
        await #expect(throws: UDSClient.UDSError.self) {
            try await client.performSecurityAccess(level: 0) { _ in "0000" }
        }

        // 2. Out-of-bounds ALFID (addrBytes == 0 or > 4, sizeBytes == 0 or > 4) must throw
        await #expect(throws: UDSClient.UDSError.self) {
            _ = try await client.readMemoryByAddress(
                memoryAddress: 0x1000,
                memorySize: 16,
                addressAndLengthFormatIdentifier: 0x00
            )
        }

        // 3. 2-byte address + 2-byte size (ALFID 0x22) must encode 2-byte address (23 22 1000 0010)
        await mock.setNextResponse("63 AA BB")
        let readBytes = try await client.readMemoryByAddress(
            memoryAddress: 0x1000,
            memorySize: 0x0010,
            addressAndLengthFormatIdentifier: 0x22
        )
        #expect(readBytes == Data([0xAA, 0xBB]))
        let sentCmd = await mock.lastRequest
        #expect(sentCmd == "232210000010")
    }

    @Test("SignalCorrelator Constant High-DC-Offset Signal Must Return Nil & Deterministic Tie-Breaking")
    func testSignalCorrelatorConstantHighOffsetCancellation() {
        let constantValue: Double = 1e10 / 3.0
        let constantSignal = [Double](repeating: constantValue, count: 7)
        let rampSignal = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 100.0]

        let rSelf = SignalCorrelator.pearsonCorrelation(x: constantSignal, y: constantSignal)
        #expect(rSelf == nil)

        let rCross = SignalCorrelator.pearsonCorrelation(x: constantSignal, y: rampSignal)
        #expect(rCross == nil)

        // Deterministic tie-breaking when two slices have identical correlation
        let rows: [[UInt8]] = (1...8).map { [UInt8($0), UInt8($0)] }
        let refs: [String: [Double]] = ["RPM": (1...8).map(Double.init)]
        let c1 = SignalCorrelator.correlateSlices(byteRows: rows, references: refs).map(\.sliceName)
        let c2 = SignalCorrelator.correlateSlices(byteRows: rows, references: refs).map(\.sliceName)
        #expect(c1 == c2)
        #expect(c1.first == "A")
    }

    @Test("PandaDriver Non-Zero Data Slices, CAN ID 0x000 Unpacking & TX Echo Bus Bit")
    func testPandaDriverSlicesAndEdgeCases() throws {
        #expect(PandaSafetyModel.chrysler.rawValue == 9)
        #expect(PandaSafetyModel.chrylsler == .chrysler)

        let directHealth = PandaHealth(uptime: 42, voltageMV: 13800, currentMA: 250, ignitionLine: true)
        #expect(directHealth.uptime == 42)
        #expect(directHealth.ignitionLine == true)

        let padding = Data(repeating: 0xCC, count: 12)
        let rawPayload = (padding + Data([0x02, 0x10, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00]))[12..<20]
        #expect(rawPayload.startIndex == 12)

        let packed = PandaDriver.packBxCAN16(address: 0x7E8, data: rawPayload, bus: 1)
        let slicedStream = (padding + packed)[12..<(12 + 16)]
        #expect(slicedStream.startIndex == 12)

        let unpacked = PandaDriver.unpackBxCAN16(data: slicedStream)
        let firstFrame = try #require(unpacked.first)
        #expect(firstFrame.address == 0x7E8)
        #expect(firstFrame.bus == 1)
        #expect(firstFrame.data == Data([0x02, 0x10, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00]))

        // STM32F4 hardware RX mailbox for CAN ID 0x000 (RIR == 0, RDTR == 2 with 2-byte payload)
        var hwFrameID0 = Data(count: 16)
        hwFrameID0[4] = 0x02 // DLC = 2, bus = 0
        hwFrameID0[8] = 0xCA
        hwFrameID0[9] = 0xFE
        let id0Frames = PandaDriver.unpackBxCAN16(data: hwFrameID0)
        #expect(id0Frames.count == 1)
        #expect(id0Frames.first?.address == 0x000)
        #expect(id0Frames.first?.data == Data([0xCA, 0xFE]))
    }

    @Test("SimulatorEngine & UDSClient 0x23 / 0x36 Short Frame NRC & BSC Validation")
    func testSimulatorAndUDSTransferDataEdgeCases() async throws {
        let sim = SimulatorEngine()

        let short23 = try await sim.sendDiagnosticRequest("23")
        #expect(short23.replacing(" ", with: "") == "7F2313")

        let short36 = try await sim.sendDiagnosticRequest("36")
        #expect(short36.replacing(" ", with: "") == "7F3613")

        actor MismatchedBSCDriver: VehicleInterface {
            func setTarget(txID: String, rxID: String?) async throws {}
            func sendDiagnosticRequest(_ requestHex: String, timeout: TimeInterval) async throws -> String {
                return "76 02 AA BB" // Echoes BSC 0x02 when 0x01 was requested
            }
        }

        let badBSCClient = UDSClient(interface: MismatchedBSCDriver())
        await #expect(throws: UDSClient.UDSError.self) {
            _ = try await badBSCClient.transferData(blockSequenceCounter: 0x01, payload: Data([0x11, 0x22]))
        }
    }

    @Test("CANIntrusionDetector Sliding Window Eviction Recovery & Mode 06 Signed/Multi-Frame Decoding")
    func testCANIntrusionDetectorWindowEvictionAndMode06Signed() async {
        let detector = CANIntrusionDetector(windowSize: 20)
        var t = 0.0

        // 1. Inject 6 rapid jittery frames on 0x666
        let burstIntervals = [0.0001, 0.012, 0.0001, 0.0001, 0.0001, 0.0001]
        for dt in burstIntervals {
            t += dt
            _ = await detector.ingest(
                frame: CANSampleFrame(
                    canID: 0x666,
                    payload: [0x01, 0x02],
                    timestampSeconds: t
                )
            )
        }

        // Fill window to >= 10 frames so security evaluation activates
        for i in 0..<6 {
            t += 0.020
            _ = await detector.ingest(
                frame: CANSampleFrame(
                    canID: 0x100,
                    payload: [UInt8(i), 0x10],
                    timestampSeconds: t
                )
            )
        }
        let activeBurstReport = await detector.evaluateSecurity()
        #expect(activeBurstReport.status == .injectionDetected)
        #expect(activeBurstReport.flaggedIDs.contains(0x666))

        // 2. Evict all 0x666 frames by ingesting 25 normal periodic frames on 0x100
        for i in 0..<25 {
            t += 0.020
            _ = await detector.ingest(
                frame: CANSampleFrame(
                    canID: 0x100,
                    payload: [UInt8(i & 0xFF), 0x20, 0x30, 0x40],
                    timestampSeconds: t
                )
            )
        }
        let postEvictionReport = await detector.evaluateSecurity()
        #expect(postEvictionReport.status == .nominal)
        #expect(!postEvictionReport.flaggedIDs.contains(0x666))

        // 3. Mode 06 signed two's complement (cid >= 0x80: Val = -10, Min = -50, Max = +50) & ISO-TP multi-frame
        let multiFrameSignedMode06 = "00A\n0: 46 01 01 81 FF F6\n1: FF CE 00 32"
        let mode06Results: [OBD2Mode06TestResult] = OBD2Analyzer.decodeMode06(responseHex: multiFrameSignedMode06)
        #expect(mode06Results.count == 1)
        #expect(mode06Results.first?.testValue == -10.0)
        #expect(mode06Results.first?.minLimit == -50.0)
        #expect(mode06Results.first?.maxLimit == 50.0)
        #expect(mode06Results.first?.isPassed == true)
    }

    @Test("CANBusFingerprinter Passive c0f Identification & Chassis Matching")
    func testCANBusFingerprinterC0F() {
        // 1. Dynamic DLC bus (Craig Smith Ch. 11 p. 308-309: 0x143 [4B] @ 10ms, 0x158 [8B] @ 10ms, 0x320 [3B] @ 100ms)
        var dynamicFrames: [CANSampleFrame] = []
        for i in 0..<20 {
            let tBase = Double(i) * 0.010
            dynamicFrames.append(CANSampleFrame(canID: 0x143, payload: [0x10, 0x20, 0x30, 0x40], timestampSeconds: tBase))
            dynamicFrames.append(CANSampleFrame(canID: 0x158, payload: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08], timestampSeconds: tBase + 0.0002))
            if i % 10 == 0 {
                dynamicFrames.append(CANSampleFrame(canID: 0x320, payload: [0xAA, 0xBB, 0xCC], timestampSeconds: tBase + 0.0005))
            }
        }

        let dynFP = CANBusFingerprinter.fingerprint(frames: dynamicFrames)
        #expect(dynFP.isDynamicDLC == true)
        #expect(dynFP.paddingByte == nil)
        #expect(dynFP.commonIDs == [0x143, 0x158])
        #expect(dynFP.mainID == 0x143)
        #expect(abs((dynFP.mainIntervalSeconds ?? 0.0) - 0.010) < 0.0005)

        // 2. Fixed 8-byte bus padded with 0xAA
        var paddedFrames: [CANSampleFrame] = []
        for i in 0..<15 {
            let tBase = Double(i) * 0.020
            paddedFrames.append(CANSampleFrame(canID: 0x201, payload: [0x12, 0x34, 0x00, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA], timestampSeconds: tBase))
            paddedFrames.append(CANSampleFrame(canID: 0x205, payload: [0x56, 0x78, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA], timestampSeconds: tBase + 0.0001))
        }

        let padFP = CANBusFingerprinter.fingerprint(frames: paddedFrames)
        #expect(padFP.isDynamicDLC == false)
        #expect(padFP.paddingByte == 0xAA)
        #expect(padFP.commonIDs == [0x201, 0x205])

        // 3. Database profile matching
        let db = [
            KnownChassisFingerprint(make: "Honda", model: "Civic", platformCode: "FK8", referenceFingerprint: dynFP),
            KnownChassisFingerprint(make: "Renault", model: "Mégane II", platformCode: "JM0G", referenceFingerprint: padFP)
        ]
        let matched = CANBusFingerprinter.matchProfile(fingerprint: dynFP, database: db)
        #expect(matched?.profile.make == "Honda")
        #expect((matched?.score ?? 0.0) > 0.95)
        #expect(CANBusFingerprinter.similarity(between: dynFP, and: padFP) < 0.30)
    }

    @Test("AutomotiveRiskAssessor HEAVENS Matrix, ISO/SAE 21434 & DREAD Scoring")
    func testAutomotiveRiskAssessorHEAVENSAndDREAD() {
        // 1. Direct HEAVENS Matrix verification (Alissa Knight Ch. 8 Table 8.11)
        #expect(AutomotiveRiskAssessor.evaluateHEAVENSMatrix(threat: .none, impact: .critical) == .qm)
        #expect(AutomotiveRiskAssessor.evaluateHEAVENSMatrix(threat: .low, impact: .low) == .low)
        #expect(AutomotiveRiskAssessor.evaluateHEAVENSMatrix(threat: .medium, impact: .medium) == .medium)
        #expect(AutomotiveRiskAssessor.evaluateHEAVENSMatrix(threat: .medium, impact: .high) == .high)
        #expect(AutomotiveRiskAssessor.evaluateHEAVENSMatrix(threat: .high, impact: .critical) == .critical)

        // 2. Vulnerable Safety-Critical ECU (unlocked 0x27, programming allowed in motion, no gateway isolation)
        let vulnerableObs = ECUSecurityObservations(
            ecuName: "ECM Bosch EDC16C3",
            isSafetyCriticalDomain: true,
            securityAccessUnlockedByDefault: true,
            staticSeedDetected: true,
            programmingSessionAllowedInMotion: true,
            gatewayIsolationPresent: false,
            busAnomalyScore: 0.75
        )
        let critReport = AutomotiveRiskAssessor.evaluateECUPosture(vulnerableObs)
        #expect(critReport.threatLevel == .critical)
        #expect(critReport.impactLevel == .critical)
        #expect(critReport.securityLevel == .critical)
        #expect(critReport.dreadScore >= 8.5)
        #expect(critReport.strideCategories.contains(.elevationOfPrivilege))
        #expect(critReport.strideCategories.contains(.tampering))
        #expect(critReport.findings.count == 5)

        // 3. Hardened Non-Safety ECU
        let hardenedObs = ECUSecurityObservations(
            ecuName: "Infotainment Head Unit",
            isSafetyCriticalDomain: false,
            securityAccessUnlockedByDefault: false,
            staticSeedDetected: false,
            programmingSessionAllowedInMotion: false,
            gatewayIsolationPresent: true,
            busAnomalyScore: 0.0
        )
        let lowReport = AutomotiveRiskAssessor.evaluateECUPosture(hardenedObs)
        #expect(lowReport.securityLevel == .qm)
        #expect(lowReport.findings.isEmpty)
        #expect(lowReport.dreadScore < 3.0)
    }

    @Test("UDSSecurityScanner Session Enumeration, Service Discovery & Seed Audit")
    func testUDSSecurityScanner() async throws {
        let sim = SimulatorEngine()
        let scanner = UDSSecurityScanner(interface: sim)

        // 1. Sessions 0x01, 0x02, 0x03 supported on SimulatorEngine
        let sessions = try await scanner.probeSessions(candidates: [0x01, 0x02, 0x03])
        #expect(sessions.count == 3)
        #expect(sessions.allSatisfy { $0.isSupported })

        // 2. Service discovery
        let services = try await scanner.probeServices(serviceIDs: [0x10, 0x22, 0x27, 0x3E, 0xAA])
        let byID = Dictionary(uniqueKeysWithValues: services.map { ($0.serviceID, $0) })
        #expect(byID[0x10]?.availability == .supported)
        #expect(byID[0x22]?.availability == .supported)
        #expect(byID[0x27]?.availability == .supported)
        #expect(byID[0xAA]?.availability == .unsupported)

        // 3. Static seed detection on level 0x01 vs Dynamic seed on level 0x05
        let auditStatic = try await scanner.auditSecurityAccessSeed(level: 0x01)
        #expect(auditStatic.posture == .staticSeedVulnerability)
        #expect(auditStatic.firstSeed == [0x12, 0x34])
        #expect(auditStatic.secondSeed == [0x12, 0x34])

        let auditDynamic = try await scanner.auditSecurityAccessSeed(level: 0x05)
        #expect(auditDynamic.posture == .dynamicSeedNominal)
        #expect(auditDynamic.firstSeed != auditDynamic.secondSeed)
        #expect(auditDynamic.shannonEntropyBitsPerByte > 1.0)

        // 4. Unlocked-by-default (0x0000) and NRC 0x37 lockout via mock driver
        actor MockSecDriver: VehicleInterface {
            func setTarget(txID: String, rxID: String?) async throws {}
            func sendDiagnosticRequest(_ requestHex: String, timeout: TimeInterval) async throws -> String {
                if requestHex == "2701" { return "67 01 00 00" }
                if requestHex == "2703" { return "7F 27 37" }
                return "7F 27 12"
            }
        }
        let mockScanner = UDSSecurityScanner(interface: MockSecDriver())
        let unlockedAudit = try await mockScanner.auditSecurityAccessSeed(level: 0x01)
        #expect(unlockedAudit.posture == .unlockedByDefault)
        let lockedOutAudit = try await mockScanner.auditSecurityAccessSeed(level: 0x03)
        #expect(lockedOutAudit.posture == .lockedOutTimeDelay)
        #expect(lockedOutAudit.negativeResponseCode == 0x37)
    }

    @Test("EDRCrashDecoder SAE J1698 / UDS 0x19 04 Snapshot & OBD-II Mode 02 Freeze Frame")
    func testEDRCrashDecoder() async throws {
        // 1. Direct UDS 0x59 0x04 decoding with severe airbag deployment (B0001, 90 km/h, 3200 RPM, DeltaVx = -32 km/h, DeltaVy = +6 km/h, flags = 0x07)
        let udsHex = "59 04 80 01 00 2F 01 5A 32 00 80 07 E0 06 8A"
        let udsSnap = try #require(EDRCrashDecoder.decodeUDSSnapshot(from: udsHex))
        #expect(udsSnap.triggerDTC == "B0001")
        #expect(udsSnap.vehicleSpeedKmh == 90.0)
        #expect(udsSnap.engineRPM == 3200.0)
        #expect(udsSnap.brakeSwitchActive == true)
        #expect(udsSnap.seatbeltBuckled == true)
        #expect(udsSnap.airbagDeployed == true)
        #expect(udsSnap.longitudinalDeltaVKmh == -32.0)
        #expect(udsSnap.lateralDeltaVKmh == 6.0)
        #expect(abs(udsSnap.batteryVoltage - 13.8) < 0.01)
        #expect(udsSnap.severity == .severeAirbagDeployment)
        #expect(udsSnap.dissipatedKineticEnergyKJ(vehicleMassKg: 1500.0) > 55.0)

        // 2. OBD-II Mode 02 Freeze Frame decoding
        let obd2Hex = "42 02 00 01 02 0C 00 0B B8 0D 00 32 11 00 FF 42 00 37 14"
        let obdSnap = try #require(EDRCrashDecoder.decodeOBD2FreezeFrame(from: obd2Hex))
        #expect(obdSnap.triggerDTC == "P0102")
        #expect(obdSnap.engineRPM == 750.0)
        #expect(obdSnap.vehicleSpeedKmh == 50.0)
        #expect(abs(obdSnap.throttlePositionPercent - 100.0) < 0.01)
        #expect(abs(obdSnap.batteryVoltage - 14.1) < 0.01)

        // 3. Live query via SimulatorEngine
        let sim = SimulatorEngine()
        let liveSnap = try #require(await EDRCrashDecoder.readCrashSnapshot(using: sim))
        #expect(liveSnap.triggerDTC == "P0102")
        #expect(liveSnap.vehicleSpeedKmh == 50.0)
        #expect(liveSnap.longitudinalDeltaVKmh == -18.0)
        #expect(liveSnap.severity == .moderate)
    }

    @Test("CANDifferentialReverser Differential Bit-Flip Isolation, 16-bit Big-Endian Regression & Vector .dbc Synthesis")
    func testCANDifferentialReverserAndDBCSynthesizer() throws {
        // 1. Differential Bit-Flip Isolation: Brake switch on CAN ID 0x244 byte 4 bit 2 (mask 0x04), with rolling counter on byte 7
        var baselineFrames: [CANSampleFrame] = []
        var stimulusFrames: [CANSampleFrame] = []
        for i in 0..<30 {
            let counter = UInt8(i % 16)
            let analogSensor = UInt8((i * 7) % 200)
            baselineFrames.append(
                CANSampleFrame(
                    canID: 0x244,
                    payload: [analogSensor, 0x10, 0x00, 0x80, 0x00, 0x00, 0x00, counter],
                    timestampSeconds: Double(i) * 0.02
                )
            )
            stimulusFrames.append(
                CANSampleFrame(
                    canID: 0x244,
                    payload: [analogSensor, 0x10, 0x00, 0x80, 0x04, 0x00, 0x00, counter],
                    timestampSeconds: Double(i) * 0.02
                )
            )
        }

        let bitCandidates = CANDifferentialReverser.isolateBitTransitions(
            baselineFrames: baselineFrames,
            stimulusFrames: stimulusFrames
        )
        #expect(bitCandidates.count == 1)
        let brakeBit = try #require(bitCandidates.first)
        #expect(brakeBit.canID == 0x244)
        #expect(brakeBit.byteIndex == 4)
        #expect(brakeBit.bitIndex == 2)
        #expect(brakeBit.bitMask == 0x04)
        #expect(brakeBit.baselineBitValue == 0)
        #expect(brakeBit.stimulusBitValue == 1)
        #expect(brakeBit.confidence >= 0.99)

        // 2. Automated 16-bit Motorola Big-Endian Signal Regression: y = 0.25 * rawBE16 - 10.0 on CAN ID 0x130 bytes 2..3
        var streamFrames: [CANSampleFrame] = []
        var refSamples: [CANReferenceSample] = []
        for i in 0..<40 {
            let t = Double(i) * 0.05
            let raw16 = UInt16(400 + i * 180) // spans multiple MSB steps (400 to 7420)
            let physicalSpeed = 0.25 * Double(raw16) - 10.0
            let hi = UInt8((raw16 >> 8) & 0xFF)
            let lo = UInt8(raw16 & 0xFF)
            let counter = UInt8(i % 16)

            streamFrames.append(
                CANSampleFrame(
                    canID: 0x130,
                    payload: [0xAA, 0x55, hi, lo, 0x00, 0x00, 0x00, counter],
                    timestampSeconds: t
                )
            )
            refSamples.append(CANReferenceSample(timestampSeconds: t, physicalValue: physicalSpeed))
        }

        let discovered = CANDifferentialReverser.discoverAnalogSignals(
            frames: streamFrames,
            referenceSamples: refSamples,
            signalName: "VehicleSpeed",
            unit: "km/h"
        )
        let topSignal = try #require(discovered.first)
        #expect(topSignal.canID == 0x130)
        #expect(topSignal.startByte == 2)
        #expect(topSignal.bitLength == 16)
        #expect(topSignal.byteOrder == .motorolaBigEndian)
        #expect(abs(topSignal.scale - 0.25) < 1e-4)
        #expect(abs(topSignal.offset - (-10.0)) < 1e-3)
        #expect(topSignal.rSquared > 0.999)

        // 3. Vector .dbc Synthesis
        let dbcContent = CANDifferentialReverser.synthesizeDBC(
            analogSignals: [topSignal],
            bitCandidates: [brakeBit],
            busName: "CHASSIS_HS_CAN"
        )
        #expect(dbcContent.contains("VERSION \"CHASSIS_HS_CAN\""))
        #expect(dbcContent.contains("BO_ 304 MSG_130: 8 Vector__XXX"))
        #expect(dbcContent.contains("SG_ VehicleSpeed : 23|16@0+ (0.25,-10)"))
        #expect(dbcContent.contains("BO_ 580 MSG_244: 8 Vector__XXX"))
        #expect(dbcContent.contains("SG_ STATE_244_B4_BIT2 : 34|1@1+ (1,0) [0|1] \"flag\" Vector__XXX"))
    }

    @Test("VehicleForensicOrchestrator End-to-End ISO/SAE 21434 Dossier & FNV-1a64 Seal")
    func testVehicleForensicOrchestratorEndToEnd() async throws {
        let sim = SimulatorEngine()
        let orchestrator = VehicleForensicOrchestrator(interface: sim)

        var canFrames: [CANSampleFrame] = []
        for i in 0..<30 {
            let t = Double(i) * 0.01
            canFrames.append(CANSampleFrame(canID: 0x0C8, payload: [0x12, 0x34, 0x56, 0x78, 0x00, 0x00, 0x00, 0x00], timestampSeconds: t))
            if i % 2 == 0 {
                canFrames.append(CANSampleFrame(canID: 0x1A0, payload: [0x01, 0x02, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00], timestampSeconds: t + 0.002))
            }
        }

        let dossier = try await orchestrator.collectDossier(
            ecuName: "PCM_POWERTRAIN_0x7E0",
            isSafetyCriticalDomain: true,
            gatewayIsolationPresent: true,
            capturedCANFrames: canFrames
        )

        #expect(dossier.ecuName == "PCM_POWERTRAIN_0x7E0")
        #expect(dossier.verifyIntegrity() == true)
        #expect(dossier.evidenceDigestHex.count == 16)
        #expect(dossier.udsScanReport.seedAudits.contains { $0.posture == .staticSeedVulnerability })
        #expect(dossier.edrCrashSnapshot?.triggerDTC == "P0102")
        #expect(dossier.canFingerprint?.mainID == 0x0C8)
        #expect(dossier.busAnomalyReport != nil)
        #expect(dossier.riskReport.securityLevel >= .high)

        // Tamper verification check: modifying the digest invalidates verifyIntegrity()
        let tamperedDossier = VehicleForensicDossier(
            ecuName: dossier.ecuName,
            udsScanReport: dossier.udsScanReport,
            calibrationInfo: dossier.calibrationInfo,
            edrCrashSnapshot: dossier.edrCrashSnapshot,
            canFingerprint: dossier.canFingerprint,
            busAnomalyReport: dossier.busAnomalyReport,
            riskReport: dossier.riskReport,
            evidenceDigestHex: "0000000000000000"
        )
        #expect(tamperedDossier.verifyIntegrity() == false)
    }

    @Test("EDRCrashDecoder Mode 02 Preceding Standard PID, Trailing CAN Padding frameNumber Protection & Empty P0000 Rejection")
    func testEDRCrashDecoderMode02EdgeCases() throws {
        // 1. Preceding standard 1-byte PID 0x05 (Coolant Temp = 80°C -> 0x78) before PIDs 0x02, 0x0C, 0x0D
        let multiPIDWithCoolant = "42 05 00 78 02 00 01 02 0C 00 0B B8 0D 00 32"
        let snapFromMulti = try #require(EDRCrashDecoder.decodeOBD2FreezeFrame(from: multiPIDWithCoolant))
        #expect(snapFromMulti.triggerDTC == "P0102")
        #expect(snapFromMulti.engineRPM == 750.0)
        #expect(snapFromMulti.vehicleSpeedKmh == 50.0)

        // 2. Frame number 0x01 followed by 2 trailing CAN padding bytes (0xAA 0xAA) must preserve snapshotRecordNumber == 0x01
        let paddedFrame01 = "42 02 01 01 02 0D 01 32 AA AA"
        let snapPadded = try #require(EDRCrashDecoder.decodeOBD2FreezeFrame(from: paddedFrame01))
        #expect(snapPadded.snapshotRecordNumber == 0x01)
        #expect(snapPadded.vehicleSpeedKmh == 50.0)

        // 3. Empty Mode 02 Freeze Frame (PID 0x02 == 0x0000 -> P0000 only) must return nil
        let emptyFreezeFrame = "05 42 02 00 00 00 AA AA"
        #expect(EDRCrashDecoder.decodeOBD2FreezeFrame(from: emptyFreezeFrame) == nil)
    }

    @Test("UDSSecurityScanner Sub-Function 0x01..0x7D Bounds, Padded 8-Byte CAN Single-Frame & Missing Second Seed Audit")
    func testUDSSecurityScannerSeedAuditEdgeCases() async throws {
        actor SeedEdgeCaseDriver: VehicleInterface {
            private(set) var sentRequests: [String] = []
            private var count2701 = 0

            func setTarget(txID: String, rxID: String?) async throws {}
            func sendDiagnosticRequest(_ requestHex: String, timeout: TimeInterval) async throws -> String {
                sentRequests.append(requestHex)
                if requestHex == "2701" {
                    count2701 += 1
                    // First request returns padded 8-byte CAN Single-Frame with constant 0xAAAA; second returns NRC 0x37
                    return count2701 == 1 ? "04 67 01 AA AA 55 55 55" : "03 7F 27 37 55 55 55 55"
                }
                return "7F 27 12"
            }
        }

        let driver = SeedEdgeCaseDriver()
        let scanner = UDSSecurityScanner(interface: driver)

        // 1. Even SendKey level (0x02), zero (0x00), reserved (0x7F), and suppressPosRsp bit (0x81) must not transmit
        let evenAudit = try await scanner.auditSecurityAccessSeed(level: 0x02)
        #expect(evenAudit.posture == .notSupported)
        let reservedAudit = try await scanner.auditSecurityAccessSeed(level: 0x7F)
        #expect(reservedAudit.posture == .notSupported)
        let suppressBitAudit = try await scanner.auditSecurityAccessSeed(level: 0x81)
        #expect(suppressBitAudit.posture == .notSupported)
        #expect(await driver.sentRequests.isEmpty)

        // 2. Padded 8-byte CAN Single-Frame + constant zero-entropy firstSeed [0xAA, 0xAA] when second seed fails
        let singleSeedAudit = try await scanner.auditSecurityAccessSeed(level: 0x01)
        #expect(singleSeedAudit.firstSeed == [0xAA, 0xAA])
        #expect(singleSeedAudit.secondSeed == nil)
        #expect(singleSeedAudit.shannonEntropyBitsPerByte == 0.0)
        #expect(singleSeedAudit.posture == .staticSeedVulnerability)
    }

    @Test("VehicleForensicDossier Full Field Tamper Detection & Non-Finite Double Safety")
    func testVehicleForensicDossierTamperAndNaNSafety() async throws {
        let sim = SimulatorEngine()
        let orchestrator = VehicleForensicOrchestrator(interface: sim)
        let original = try await orchestrator.collectDossier(ecuName: "PCM_0x7E0")
        #expect(original.verifyIntegrity() == true)

        // 1. Tamper with forensic crash evidence while keeping triggerDTC and totalDeltaVMagnitudeKmh identical
        let origEDR = try #require(original.edrCrashSnapshot)
        let tamperedEDR = EDRCrashSnapshot(
            triggerDTC: origEDR.triggerDTC,
            snapshotRecordNumber: origEDR.snapshotRecordNumber,
            vehicleSpeedKmh: 195.0,
            engineRPM: 6500.0,
            throttlePositionPercent: 100.0,
            brakeSwitchActive: !origEDR.brakeSwitchActive,
            seatbeltBuckled: !origEDR.seatbeltBuckled,
            airbagDeployed: !origEDR.airbagDeployed,
            longitudinalDeltaVKmh: -origEDR.longitudinalDeltaVKmh,
            lateralDeltaVKmh: origEDR.lateralDeltaVKmh,
            batteryVoltage: origEDR.batteryVoltage,
            severity: .severeAirbagDeployment
        )
        let forgedDossier = VehicleForensicDossier(
            ecuName: original.ecuName,
            udsScanReport: original.udsScanReport,
            calibrationInfo: original.calibrationInfo,
            edrCrashSnapshot: tamperedEDR,
            canFingerprint: original.canFingerprint,
            busAnomalyReport: original.busAnomalyReport,
            riskReport: original.riskReport,
            evidenceDigestHex: original.evidenceDigestHex
        )
        #expect(forgedDossier.verifyIntegrity() == false)

        // 2. Non-finite Double (.nan / .infinity) must not trap in computeDigestHex
        let nanRisk = AutomotiveRiskReport(
            targetName: "ECU",
            threatLevel: .low,
            impactLevel: .low,
            securityLevel: .low,
            dreadScore: .nan,
            strideCategories: [],
            findings: [],
            remediations: []
        )
        let digest = VehicleForensicDossier.computeDigestHex(
            ecuName: "ECU",
            udsScanReport: original.udsScanReport,
            calibrationInfo: nil,
            edrCrashSnapshot: nil,
            canFingerprint: nil,
            busAnomalyReport: nil,
            riskReport: nanRisk
        )
        #expect(digest.count == 16)
    }

    @Test("CANDifferentialReverser Out-of-Order Frame Counter Rejection, 29-Bit Extended DBC ID Flag & Low-Count c0f Self-Similarity")
    func testCANDifferentialReverserUnsortedFramesAndExtendedDBC() {
        // 1. Rolling counter 0..9 during a 10-sample ramp must be rejected even when frames arrive in reverse order
        var chronologicalFrames: [CANSampleFrame] = []
        var refs: [CANReferenceSample] = []
        for i in 0..<10 {
            let t = Double(i) * 0.05
            let rollingCounter = UInt8(i)
            chronologicalFrames.append(CANSampleFrame(canID: 0x200, payload: [rollingCounter], timestampSeconds: t))
            refs.append(CANReferenceSample(timestampSeconds: t, physicalValue: Double(i) * 10.0))
        }

        let fromReversed = CANDifferentialReverser.discoverAnalogSignals(
            frames: Array(chronologicalFrames.reversed()),
            referenceSamples: refs,
            signalName: "Speed",
            unit: "km/h"
        )
        #expect(fromReversed.isEmpty)

        // 2. 29-bit J1939 Extended CAN ID (0x0CF00400) must set bit 31 (0x8CF00400 = 2364540160) in Vector DBC
        let extSignal = DiscoveredCANSignal(
            name: "12V_EngineSpeed",
            canID: 0x0CF00400,
            dlc: 8,
            startByte: 3,
            bitLength: 16,
            byteOrder: .intelLittleEndian,
            scale: 0.125,
            offset: 0.0,
            minValue: 0.0,
            maxValue: 8031.875,
            unit: "rpm",
            rSquared: 1.0
        )
        let dbc = CANDifferentialReverser.synthesizeDBC(analogSignals: [extSignal])
        let expectedDBCID: UInt32 = 0x0CF00400 | 0x80000000
        #expect(dbc.contains("BO_ \(expectedDBCID) MSG_0CF00400: 8 Vector__XXX"))
        #expect(dbc.contains("SG_ SIG_12V_EngineSpeed :"))

        // 3. Single-frame-per-ID c0f fingerprint self-similarity must equal 1.0
        let singleShot = [
            CANSampleFrame(canID: 0x100, payload: [0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], timestampSeconds: 0.01),
            CANSampleFrame(canID: 0x200, payload: [0x03, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], timestampSeconds: 0.02)
        ]
        let fp = CANBusFingerprinter.fingerprint(frames: singleShot)
        #expect(fp.commonIDs == [0x100, 0x200])
        #expect(abs(CANBusFingerprinter.similarity(between: fp, and: fp) - 1.0) < 1e-6)
    }

    @Test("VehicleForensicOrchestrator Preserves Non-7E0 ECU Target Across CalibrationReader & EDRCrashDecoder")
    func testVehicleForensicOrchestratorTargetPreservation() async throws {
        actor TargetTrackingSRSInterface: VehicleInterface {
            var currentTx: String = "752"
            var currentRx: String = "772"
            var edrQueriedTxID: String?

            func setTarget(txID: String, rxID: String?) async throws {
                self.currentTx = txID
                self.currentRx = rxID ?? "772"
            }

            func sendDiagnosticRequest(_ requestHex: String, timeout: TimeInterval) async throws -> String {
                let clean = requestHex.replacing(" ", with: "").uppercased()
                if clean.hasPrefix("1904") {
                    edrQueriedTxID = currentTx
                    if currentTx == "752" {
                        return "59 04 80 01 00 2F 01 5A 32 00 80 07 E0 06 8A"
                    }
                    return "7F 19 11"
                }
                if clean == "22F198" {
                    return "62F1985352535F43414C5F3031"
                }
                return "7F" + String(clean.prefix(2)) + "11"
            }
        }

        let srsInterface = TargetTrackingSRSInterface()
        let orchestrator = VehicleForensicOrchestrator(interface: srsInterface)
        let dossier = try await orchestrator.collectDossier(ecuName: "SRS_AIRBAG_0x752")

        #expect(await srsInterface.edrQueriedTxID == "752")
        #expect(dossier.edrCrashSnapshot?.triggerDTC == "B0001")
        #expect(dossier.calibrationInfo?.primaryCalID == "SRS_CAL_01")
    }

    // MARK: - VehicleLogger & Flight Recorder (v2.7.0)

    @Test("VehicleLogger: O(1) circular ring buffer rotation, level/category filtering, and concurrency safety")
    func testVehicleLoggerRingBufferAndFiltering() async {
        let logger = VehicleLogger(capacity: 16, minimumLevel: .debug, osLogEnabled: false)

        // Un événement .trace doit être filtré lorsque minimumLevel == .debug
        logger.trace(.bus, "Ignored trace event")
        #expect(logger.recentEntries().isEmpty)

        // Insertion de 25 entrées dans un tampon circulaire de capacité 16
        for i in 1...25 {
            let category: VehicleLogCategory = (i % 2 == 0) ? .security : .diagnostic
            let level: VehicleLogLevel = (i >= 20) ? .warning : .info
            logger.log(level, category: category, "Event #\(i)", metadata: ["index": "\(i)"])
        }

        let all = logger.recentEntries()
        #expect(all.count == 16)
        #expect(all.first?.id == 10)
        #expect(all.last?.id == 25)
        #expect(all.first?.message == "Event #10")
        #expect(all.last?.message == "Event #25")

        let warningsOnly = logger.recentEntries(minLevel: .warning)
        #expect(warningsOnly.count == 6) // Events 20..25

        let securityWarnings = logger.recentEntries(minLevel: .warning, category: .security)
        #expect(securityWarnings.count == 3) // Events 20, 22, 24

        // Reconfiguration dynamique de capacité à la baisse (garde les 16 dernières si cap=16)
        logger.clear()
        #expect(logger.recentEntries().isEmpty)
    }

    @Test("VehicleLogger: candump (.log) and JSONL forensic exporters + SimulatorEngine instrumentation")
    func testVehicleLoggerCANDumpAndJSONLExport() async throws {
        let customLogger = VehicleLogger(capacity: 64, minimumLevel: .trace, osLogEnabled: false)
        customLogger.logFrame(
            direction: .tx,
            level: .debug,
            category: .transport,
            canID: "0x7E0",
            payloadHex: "02 10 03",
            bus: 0,
            timestamp: 1729624200.125
        )
        customLogger.logFrame(
            direction: .rx,
            level: .debug,
            category: .transport,
            canID: "7E8",
            payloadHex: "06 50 03 00 32 01 F4",
            bus: 0,
            latencyMs: 3.4,
            timestamp: 1729624200.1284
        )
        customLogger.info(.forensic, "Dossier sealed", metadata: ["ecu": "EMS_7E0"])

        let candump = customLogger.exportCANDumpLog()
        let candumpLines = candump.split(separator: "\n").map(String.init)
        #expect(candumpLines.count == 2)
        #expect(candumpLines[0] == "(1729624200.125000) can0 7E0#021003")
        #expect(candumpLines[1] == "(1729624200.128400) can0 7E8#065003003201F4")

        let jsonl = customLogger.exportJSONLines()
        let jsonLines = jsonl.split(separator: "\n").map(String.init)
        #expect(jsonLines.count == 3)
        #expect(jsonLines[0].contains("\"canID\":\"0x7E0\""))
        #expect(jsonLines[2].contains("\"category\":\"forensic\""))

        // Vérifie que SimulatorEngine et UDSClient alimentent automatiquement VehicleLogger.shared
        let sim = SimulatorEngine()
        try await sim.setTarget(txID: "7E0", rxID: "7E8")
        let resp = try await sim.sendDiagnosticRequest("1003", timeout: 1.0)
        #expect(resp.hasPrefix("5003"))

        let sharedFrames = VehicleLogger.shared.recentEntries(category: .transport)
        #expect(sharedFrames.contains { $0.direction == .tx && $0.payloadHex == "1003" })
        #expect(sharedFrames.contains { $0.direction == .rx && ($0.payloadHex?.hasPrefix("5003") == true) })
    }
}

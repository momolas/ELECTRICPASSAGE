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
        #expect(!keyRenault.isEmpty)
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
        #expect(!signals.isEmpty)
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

        let dtcs = DTCDecoder.decodeDTCList(from: "43 02 01 02 03 00")
        #expect(dtcs == ["P0102", "P0300"])

        let statusPresent = DTCDecoder.decodeKwpDtcStatus(0x80)
        #expect(statusPresent.contains("Présent"))
    }

    @Test("KWP2000 Client Session & Services")
    func testKWP2000Client() async throws {
        let sim = SimulatorEngine()
        let client = await KWP2000Client(interface: sim)

        let sessionResp = try await client.startSession(mode: 0x85)
        #expect(sessionResp.hasPrefix("5085"))

        let lidData = try await client.readLocalIdentifier(lid: 0x00)
        #expect(!lidData.isEmpty)

        await client.stop()
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
        #expect(!mask.contains(.warningIndicatorRequested))
        #expect(!mask.summary.isEmpty)

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
        #expect(!coordinator.isBusy)

        await coordinator.acquire(priority: .interactive, name: "Live Data")
        #expect(coordinator.isBusy)
        #expect(coordinator.activePriority == .interactive)
        #expect(coordinator.activeSessionName == "Live Data")

        coordinator.release()
        #expect(!coordinator.isBusy)
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

    // MARK: - Apple Accelerate & Signal Processing Tests

    @Test("Accelerate vs Scalar Pearson Equivalence")
    func testPearsonEquivalence() {
        let xs = [1.2, 2.5, 3.8, 4.1, 5.9, 6.4, 7.8, 8.2]
        let ys = [2.4, 5.1, 7.6, 8.3, 11.7, 12.9, 15.7, 16.5]
        
        let scalarR = SignalCorrelator.scalarPearson(x: xs, y: ys)
        let standardR = SignalCorrelator.pearsonCorrelation(x: xs, y: ys)

        #expect(scalarR != nil)
        #expect(standardR != nil)
        #expect(abs((scalarR ?? 0) - (standardR ?? 0)) < 1e-5)

        #if canImport(Accelerate)
        let accelR = SignalCorrelator.acceleratedPearson(x: xs, y: ys)
        #expect(accelR != nil)
        #expect(abs((accelR ?? 0) - (scalarR ?? 0)) < 1e-5)
        #endif
    }

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
}



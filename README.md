# 🚗 VehicleKit (`ELECTRICPASSAGE`)

[![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20|%20macOS%20|%20visionOS%20|%20watchOS%20|%20tvOS-blue.svg)](https://developer.apple.com/swift/)
[![Version](https://img.shields.io/badge/Version-2.4.0-informational.svg)]()
[![Tests](https://img.shields.io/badge/Tests-Passing%20(70/70)-brightgreen.svg)]()

**VehicleKit** is a high-performance, modular, pure **Swift 6** engine designed for automotive diagnostics, ECU calibration analysis, OBD flashing protocols, CAN/LIN bus telemetry, and anti-fraud machine learning.

Built from the ground up with **Swift Strict Concurrency (`Sendable`, `actor`)**, zero UI dependencies, and Apple Accelerate (`vDSP`) vectorization for real-time automotive applications.

---

## 🏛️ Architecture & Modules

```text
VehicleKit (Umbrella Module)
├── 🟢 VehicleCore             # BusCoordinator (priority lock), FormulaEvaluator (AST), HexParsing, UDSNRC, J1939, DDT2000 & OBDb converters
├── 🔵 VehicleISOTP            # ISO 15765-2 multi-frame reassembly (12-bit & 32-bit FF, CAN-FD SF, strict 8-byte padding)
├── 🟣 VehicleDiagnostic       # UDS (ISO 14229), KWP2000 (ISO 14230), CalibrationReader, ECUFlashValidator, VINReader, SecurityAccess (0x27)
├── 🟠 VehicleTransport        # VehicleInterface protocol, BLE OBD-II driver (ELM327/STN), DoIP (ISO 13400-2) & dynamic SimulatorEngine
├── 🔴 VehicleTransportPanda   # Comma.ai Panda driver, STM32F4 16-byte bxCAN framing, TX echo filtering & 41-byte PandaHealth telemetry
├── 📊 VehicleAnalytics        # Multi-rate Sampler actor, Pearson/Cross-Correlation (vDSP), Biquad IIR/Median filters & FFT SpectralAnalyzer
└── 🧠 VehicleML               # OdometerFraudAuditor, BatteryHealthEstimator, CANIntrusionDetector & SemanticSignalClassifier
```

---

## ✨ Key Capabilities (v2.4.0)

### 1. ECU Calibration Audit & OBD Flasher Primitives (`VehicleDiagnostic`)
* **`CalibrationReader`**:
  * Multi-protocol software & calibration fingerprinting across **OBD-II Mode 09** (`09 04` CalID, `09 06` CVN), **UDS Service `0x22`** (`F198`, `F182`, `F199`, `F188`, `F191`), and **Renault KWP2000 `0x21 80`** (20-byte identification block).
  * Automated remap and tampering detection (`isSuspiciousTuningDetected`) with token-aware filtering (`STAGE1`, `EGR_OFF`, `DPF_OFF`, `AUTOTUNER`, `WINOLS`, zeroed CVN).
* **`ECUFlashValidator`**:
  * **Checksums**: IEEE 802.3 `crc32(_:)` and 16-bit Big-Endian modular word sum `checksum16(_:)` used on Bosch/Siemens calibration blocks.
  * **Static Binary Inspection (`ECUBinaryMetadata`)**: Embedded ASCII HW/SW signature scanner, ROM size validation, and blank/corrupted (`0x00`/`0xFF`) detection.
  * **Smart Sector Diff (`compare(original:modified:sectorSize:ecuCalibration:)`)**: Sector-by-sector comparison between Stock (`ORI`) and Modified (`MOD`) binaries with hardware/software compatibility enforcement.
  * **Pre-Flight Safety Gate (`evaluatePreFlight`)**: Enforces minimum battery voltage ($\ge 12.5\text{ V}$), local Stock ORI vault backup presence, and HW/SW signature matching before flashing.
* **`UDSClient` & `KWP2000Client` Memory Transfer**:
  * Full support for `0x23 ReadMemoryByAddress`, `0x34 RequestDownload` (with `maxNumberOfBlockLength` negotiation), `0x35 RequestUpload`, `0x36 TransferData`, `0x37 RequestTransferExit`, `0x31 01 FF00 EraseMemory`, and `0x31 01 FF01 / 0202 CheckProgrammingDependencies`.
  * Automatic handling of `NRC 0x78` (`requestCorrectlyReceived-ResponsePending`) and atomic session transactions (`withAtomicTransaction`).

### 2. Comma.ai Panda Hardware & Transport (`VehicleTransportPanda` & `VehicleTransport`)
* **White Panda (`v1.7.5` STM32F4) Native Support**:
  * `PandaDriver.packBxCAN16` / `unpackBxCAN16` for 16-byte `CAN_FIFOMailBox_TypeDef` frames with hardware `TXRQ` bit (`0b001` / `0b101`) and automatic filtering of Panda TX receipt echoes (`bus & 0x80 != 0`).
  * `PandaHealth` parser for the 41-byte USB control `0xD2` health structure (uptime, voltage, CAN RX/TX/FWD error counters, safety model, harness status).

### 3. Signal Processing & Automotive Machine Learning (`VehicleAnalytics` & `VehicleML`)
* **DSP & Telemetry**: Zero-transient pre-warmed Biquad IIR low-pass filter, boundary-clamped Median filter, DC-centered vDSP FFT `SpectralAnalyzer`, and numerically stable mean-centered Pearson & time-lag cross-correlation.
* **Anti-Fraud & Security ML**:
  * `OdometerFraudAuditor`: Multi-ECU mileage spread analysis, freeze-frame & DPF history cross-checking, and `0xFFFF`/`655350` unprogrammed sentinel filtering.
  * `BatteryHealthEstimator`: Internal resistance ($R_i$) and State-of-Health (SoH) estimation from cranking voltage sag with thermal compensation.
  * `CANIntrusionDetector`: Sliding-window Shannon entropy and inter-arrival time (IAT) flood/spoofing detection.

---

## 🚀 Quick Start

### Installation via Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/momolas/ELECTRICPASSAGE.git", branch: "main")
]
```

### Usage Example: ECU Calibration Audit, Sector Diff & UDS Flash Sequence

```swift
import VehicleKit

let transport = SimulatorEngine()

// 1. Read ECU Calibration Identity (CalID, CVN, HW/SW)
if let calInfo = try await CalibrationReader.read(interface: transport) {
    print("CalID: \(calInfo.primaryCalID ?? "-"), CVN: \(calInfo.primaryCVN ?? "-")")
    print("Suspicious Remap Detected: \(calInfo.isSuspiciousTuningDetected)")
}

// 2. Inspect & Compare Stock ORI vs Stage 1 Binary
let stockData = ECUFlashValidator.buildSyntheticStockCalibration(calibration: nil, size: 65536)
let stage1Data = ECUFlashValidator.buildSimulatedStage1Calibration(from: stockData)
let diff = ECUFlashValidator.compare(original: stockData, modified: stage1Data, sectorSize: 4096)
print("Modified Sectors: \(diff.modifiedSectors.count)/\(diff.totalSectors) (\(diff.changedBytesCount) bytes)")

// 3. Execute UDS Memory Upload / Download
let uds = UDSClient(interface: transport)
_ = try await uds.startSession(sessionType: 0x02)
let maxBlockLen = try await uds.requestDownload(memoryAddress: 0x040000, uncompressedSize: 65536)
_ = try await uds.transferData(blockSequenceCounter: 1, payload: stage1Data.prefix(maxBlockLen))
_ = try await uds.requestTransferExit()
await uds.stop()
```

---

## 🧪 Testing & Validation

Run the 70 automated unit tests using **Swift Testing**:

```bash
swift test
```

---

## 📄 License

MIT License. See `LICENSE` for details.

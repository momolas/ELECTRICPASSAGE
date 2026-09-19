# 🚗 VehicleKit

[![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20|%20macOS%20|%20visionOS%20|%20watchOS%20|%20Linux-blue.svg)](https://developer.apple.com/swift/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/Tests-Passing%20(24/24)-brightgreen.svg)]()

**VehicleKit** is a high-performance, modular, and pure Swift 6 framework designed for automotive communication, diagnostic protocols, and CAN/LIN bus telemetry.

Built from the ground up with **Swift Concurrency (Strict Concurrency & Sendable)**, zero UI dependencies, and optimal memory layouts for real-time applications.

---

## 🏛️ Architecture & Targets

```
VehicleKit
├── 🟢 VehicleCore             # Hex parsing, FormulaEvaluator (JS/Math), UDS Negative Response Codes (NRC), Unified ECU Profiles
├── 🔵 VehicleISOTP            # ISO 15765-2 multi-frame reassembly, flow control & 8-byte strict padding
├── 🟣 VehicleDiagnostic       # KWP2000 (ISO 14230), UDS (ISO 14229), SecurityAccess (0x27), Freeze Frame, VINReader
├── 🟠 VehicleTransport        # Hardware abstraction protocol, BLE OBD-II driver (ELM/STN), DoIP (ISO 13400) & ECU SimulatorEngine
├── 🔴 VehicleTransportPanda   # Comma.ai Panda driver & Safety Models
└── 📊 VehicleAnalytics        # Multi-Rate Sampler & Pearson Signal Correlation
```

---

## 🚀 Quick Start

### 1. Installation via Swift Package Manager

Add `VehicleKit` to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/momolas/VehicleKit.git", from: "2.0.0")
]
```

Or add individual submodules to keep your binary lightweight:
```swift
.target(
    name: "MyDiagnosticTool",
    dependencies: [
        .product(name: "VehicleDiagnostic", package: "VehicleKit"),
        .product(name: "VehicleTransportPanda", package: "VehicleKit")
    ]
)
```

---

## 2. Usage Examples

### Single-line import
```swift
import VehicleKit

// 1. Initialize hardware transport (Panda or Simulator)
let transport = SimulatorEngine()
try await transport.setTarget(txID: "745", rxID: "765")

// 2. Send Diagnostic Request
let response = try await transport.sendDiagnosticRequest("2100", timeout: 2.0)
print("Diagnostic Response: \(response)")

// 3. Decode Negative Response Codes (NRC)
if let nrc = UDSNRC.parse(from: response) {
    print("ECU Rejected Request: \(nrc.title)")
    print("Action Advice: \(nrc.actionAdvice)")
}
```

#### ISO-TP Reassembly
```swift
let reassembler = ISOTPReassembler()

let frameData = Data([0x03, 0x22, 0x01, 0x02, 0xAA, 0xAA, 0xAA, 0xAA])
let result = await reassembler.processFrame(address: 0x7E8, data: frameData)

if case .completed(let payload) = result {
    print("Reassembled payload: \(payload.map { String(format: "%02X", $0) }.joined())")
}
```

#### SecurityAccess (0x27) Seed/Key Calculation
```swift
let key = SecurityAccessManager.calculateKey(
    seedHex: "12 34",
    algorithm: .renaultStandard,
    maskHex: "5A 5A"
)
```

---

## 🧪 Testing & Validation

Run the full automated test suite with Swift Testing:

```bash
swift test
```

---

## 📄 License

MIT License. See `LICENSE` for details.

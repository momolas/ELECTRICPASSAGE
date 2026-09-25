import Foundation
import VehicleCore

/// Catalogue exhaustif des PIDs SAE J1979 Mode-01 normalisés
public enum StandardPids: Sendable {

    public static let all: [PidDef] = [
        PidDef(id: "monitor_status",       displayName: "Monitor status",        ecu: "engine", mode: "01", pid: "01", unit: "",     formula: "0",                                  category: .diagnostics, min: nil, max: nil),
        PidDef(id: "fuel_system_status",   displayName: "Fuel system status",    ecu: "engine", mode: "01", pid: "03", unit: "",     formula: "0",                                  category: .engine,      min: nil, max: nil),
        PidDef(id: "engine_load",          displayName: "Engine load",           ecu: "engine", mode: "01", pid: "04", unit: "%",    formula: "A*100/255",                          category: .engine,      min: 0,   max: 100),
        PidDef(id: "coolant_temp",         displayName: "Coolant temp",          ecu: "engine", mode: "01", pid: "05", unit: "°C",   formula: "A-40",                               category: .temperature, min: -40, max: 215),
        PidDef(id: "stft_b1",              displayName: "Short fuel trim B1",    ecu: "engine", mode: "01", pid: "06", unit: "%",    formula: "A*100/128-100",                      category: .emissions,   min: nil, max: nil),
        PidDef(id: "ltft_b1",              displayName: "Long fuel trim B1",     ecu: "engine", mode: "01", pid: "07", unit: "%",    formula: "A*100/128-100",                      category: .emissions,   min: nil, max: nil),
        PidDef(id: "fuel_pressure",        displayName: "Fuel pressure",        ecu: "engine", mode: "01", pid: "0A", unit: "kPa",  formula: "A*3",                                category: .engine,      min: nil, max: nil),
        PidDef(id: "intake_map",           displayName: "Intake MAP",            ecu: "engine", mode: "01", pid: "0B", unit: "kPa",  formula: "A",                                  category: .engine,      min: nil, max: nil),
        PidDef(id: "rpm",                  displayName: "Engine RPM",            ecu: "engine", mode: "01", pid: "0C", unit: "rpm",  formula: "(A*256+B)/4",                        category: .rpm,         min: 0,   max: 8000),
        PidDef(id: "speed",                displayName: "Vehicle speed",         ecu: "engine", mode: "01", pid: "0D", unit: "km/h", formula: "A",                                  category: .speed,       min: 0,   max: 255),
        PidDef(id: "timing_advance",       displayName: "Timing advance",        ecu: "engine", mode: "01", pid: "0E", unit: "°",    formula: "A/2-64",                             category: .engine,      min: nil, max: nil),
        PidDef(id: "iat",                  displayName: "Intake air temp",       ecu: "engine", mode: "01", pid: "0F", unit: "°C",   formula: "A-40",                               category: .temperature, min: nil, max: nil),
        PidDef(id: "maf",                  displayName: "MAF",                   ecu: "engine", mode: "01", pid: "10", unit: "g/s",  formula: "(A*256+B)/100",                      category: .engine,      min: nil, max: nil),
        PidDef(id: "throttle_pos",         displayName: "Throttle position",     ecu: "engine", mode: "01", pid: "11", unit: "%",    formula: "A*100/255",                          category: .engine,      min: nil, max: nil),
        PidDef(id: "o2_b1s1",              displayName: "O2 B1S1 voltage",       ecu: "engine", mode: "01", pid: "14", unit: "V",    formula: "A/200",                              category: .emissions,   min: nil, max: nil),
        PidDef(id: "o2_b1s2",              displayName: "O2 B1S2 voltage",       ecu: "engine", mode: "01", pid: "15", unit: "V",    formula: "A/200",                              category: .emissions,   min: nil, max: nil),
        PidDef(id: "obd_standard",         displayName: "OBD standard",          ecu: "engine", mode: "01", pid: "1C", unit: "",     formula: "A",                                  category: .diagnostics, min: nil, max: nil),
        PidDef(id: "run_time",             displayName: "Run time since start",  ecu: "engine", mode: "01", pid: "1F", unit: "s",    formula: "A*256+B",                            category: .engine,      min: nil, max: nil),
        PidDef(id: "distance_with_mil",    displayName: "Distance with MIL on",  ecu: "engine", mode: "01", pid: "21", unit: "km",   formula: "A*256+B",                            category: .diagnostics, min: nil, max: nil),
        PidDef(id: "fuel_rail_pressure",   displayName: "Fuel rail pressure",    ecu: "engine", mode: "01", pid: "23", unit: "kPa",  formula: "(A*256+B)*10",                       category: .engine,      min: nil, max: nil),
        PidDef(id: "egr_command",          displayName: "Commanded EGR",         ecu: "engine", mode: "01", pid: "2C", unit: "%",    formula: "A*100/255",                          category: .emissions,   min: nil, max: nil),
        PidDef(id: "egr_error",            displayName: "EGR error",             ecu: "engine", mode: "01", pid: "2D", unit: "%",    formula: "A*100/128-100",                      category: .emissions,   min: nil, max: nil),
        PidDef(id: "evap_purge_cmd",       displayName: "Commanded evap purge",  ecu: "engine", mode: "01", pid: "2E", unit: "%",    formula: "A*100/255",                          category: .emissions,   min: nil, max: nil),
        PidDef(id: "fuel_level",           displayName: "Fuel level",            ecu: "engine", mode: "01", pid: "2F", unit: "%",    formula: "A*100/255",                          category: .engine,      min: nil, max: nil),
        PidDef(id: "warmups_since_clear",  displayName: "Warmups since DTC clear",ecu:"engine", mode: "01", pid: "30", unit: "",     formula: "A",                                  category: .diagnostics, min: nil, max: nil),
        PidDef(id: "distance_since_clear", displayName: "Distance since DTC clear",ecu:"engine",mode: "01", pid: "31", unit: "km",   formula: "A*256+B",                            category: .diagnostics, min: nil, max: nil),
        PidDef(id: "evap_pressure",        displayName: "Evap system pressure",  ecu: "engine", mode: "01", pid: "32", unit: "Pa",   formula: "(A*256+B)/4",                        category: .emissions,   min: nil, max: nil),
        PidDef(id: "barometric",           displayName: "Barometric pressure",   ecu: "engine", mode: "01", pid: "33", unit: "kPa",  formula: "A",                                  category: .engine,      min: nil, max: nil),
        PidDef(id: "cat_temp_b1s1",        displayName: "Catalyst temp B1S1",    ecu: "engine", mode: "01", pid: "3C", unit: "°C",   formula: "(A*256+B)/10-40",                    category: .emissions,   min: nil, max: nil),
        PidDef(id: "cat_temp_b2s1",        displayName: "Catalyst temp B2S1",    ecu: "engine", mode: "01", pid: "3D", unit: "°C",   formula: "(A*256+B)/10-40",                    category: .emissions,   min: nil, max: nil),
        PidDef(id: "cat_temp_b1s2",        displayName: "Catalyst temp B1S2",    ecu: "engine", mode: "01", pid: "3E", unit: "°C",   formula: "(A*256+B)/10-40",                    category: .emissions,   min: nil, max: nil),
        PidDef(id: "cat_temp_b2s2",        displayName: "Catalyst temp B2S2",    ecu: "engine", mode: "01", pid: "3F", unit: "°C",   formula: "(A*256+B)/10-40",                    category: .emissions,   min: nil, max: nil),
        PidDef(id: "control_module_v",     displayName: "Control module voltage",ecu: "engine", mode: "01", pid: "42", unit: "V",    formula: "(A*256+B)/1000",                     category: .diagnostics, min: nil, max: nil),
        PidDef(id: "abs_load",             displayName: "Absolute load",         ecu: "engine", mode: "01", pid: "43", unit: "%",    formula: "(A*256+B)*100/255",                  category: .engine,      min: nil, max: nil),
        PidDef(id: "afr_command",          displayName: "Commanded AFR",         ecu: "engine", mode: "01", pid: "44", unit: "",     formula: "(A*256+B)/32768",                    category: .emissions,   min: nil, max: nil),
        PidDef(id: "rel_throttle",         displayName: "Relative throttle pos", ecu: "engine", mode: "01", pid: "45", unit: "%",    formula: "A*100/255",                          category: .engine,      min: nil, max: nil),
        PidDef(id: "ambient_temp",         displayName: "Ambient air temp",      ecu: "engine", mode: "01", pid: "46", unit: "°C",   formula: "A-40",                               category: .temperature, min: nil, max: nil),
        PidDef(id: "abs_throttle_b",       displayName: "Absolute throttle B",   ecu: "engine", mode: "01", pid: "47", unit: "%",    formula: "A*100/255",                          category: .engine,      min: nil, max: nil),
        PidDef(id: "accel_pedal_d",        displayName: "Accelerator pedal D",   ecu: "engine", mode: "01", pid: "49", unit: "%",    formula: "A*100/255",                          category: .engine,      min: nil, max: nil),
        PidDef(id: "accel_pedal_e",        displayName: "Accelerator pedal E",   ecu: "engine", mode: "01", pid: "4A", unit: "%",    formula: "A*100/255",                          category: .engine,      min: nil, max: nil),
        PidDef(id: "throttle_actuator_cmd",displayName: "Commanded throttle act.",ecu:"engine", mode: "01", pid: "4C", unit: "%",    formula: "A*100/255",                          category: .engine,      min: nil, max: nil),
        PidDef(id: "time_mil_on",          displayName: "Time run with MIL on",  ecu: "engine", mode: "01", pid: "4D", unit: "min",  formula: "A*256+B",                            category: .diagnostics, min: nil, max: nil),
        PidDef(id: "time_since_clear",     displayName: "Time since DTC clear",  ecu: "engine", mode: "01", pid: "4E", unit: "min",  formula: "A*256+B",                            category: .diagnostics, min: nil, max: nil),
        PidDef(id: "fuel_type",            displayName: "Fuel type",             ecu: "engine", mode: "01", pid: "51", unit: "",     formula: "A",                                  category: .engine,      min: nil, max: nil),
        PidDef(id: "ethanol_pct",          displayName: "Ethanol %",             ecu: "engine", mode: "01", pid: "52", unit: "%",    formula: "A*100/255",                          category: .engine,      min: nil, max: nil),
        PidDef(id: "abs_evap_pressure",    displayName: "Abs evap vapor pressure",ecu:"engine", mode: "01", pid: "53", unit: "kPa",  formula: "(A*256+B)/200",                      category: .emissions,   min: nil, max: nil),
        PidDef(id: "evap_vapor_pressure",  displayName: "Evap vapor pressure",   ecu: "engine", mode: "01", pid: "54", unit: "Pa",   formula: "(A*256+B)-32767",                    category: .emissions,   min: nil, max: nil),
        PidDef(id: "stft_b1b3_o2",         displayName: "STFT 2nd O2 B1+B3",     ecu: "engine", mode: "01", pid: "55", unit: "%",    formula: "A*100/128-100",                      category: .emissions,   min: nil, max: nil),
        PidDef(id: "ltft_b1b3_o2",         displayName: "LTFT 2nd O2 B1+B3",     ecu: "engine", mode: "01", pid: "56", unit: "%",    formula: "A*100/128-100",                      category: .emissions,   min: nil, max: nil),
        PidDef(id: "stft_b2b4_o2",         displayName: "STFT 2nd O2 B2+B4",     ecu: "engine", mode: "01", pid: "57", unit: "%",    formula: "A*100/128-100",                      category: .emissions,   min: nil, max: nil),
        PidDef(id: "ltft_b2b4_o2",         displayName: "LTFT 2nd O2 B2+B4",     ecu: "engine", mode: "01", pid: "58", unit: "%",    formula: "A*100/128-100",                      category: .emissions,   min: nil, max: nil),
        PidDef(id: "fuel_rail_abs_pressure",displayName:"Fuel rail abs pressure",ecu: "engine", mode: "01", pid: "59", unit: "kPa",  formula: "(A*256+B)*10",                       category: .engine,      min: nil, max: nil),
        PidDef(id: "rel_accel_pedal",      displayName: "Relative pedal pos",    ecu: "engine", mode: "01", pid: "5A", unit: "%",    formula: "A*100/255",                          category: .engine,      min: nil, max: nil),
        PidDef(id: "hybrid_pack_soc",      displayName: "Hybrid battery SOC",    ecu: "engine", mode: "01", pid: "5B", unit: "%",    formula: "A*100/255",                          category: .hybrid,      min: 0,   max: 100),
        PidDef(id: "engine_oil_temp",      displayName: "Engine oil temp",       ecu: "engine", mode: "01", pid: "5C", unit: "°C",   formula: "A-40",                               category: .temperature, min: -40, max: 215),
        PidDef(id: "fuel_injection_timing",displayName: "Fuel injection timing", ecu: "engine", mode: "01", pid: "5D", unit: "°",    formula: "(A*256+B)/128-210",                  category: .engine,      min: nil, max: nil),
        PidDef(id: "engine_fuel_rate",     displayName: "Engine fuel rate",      ecu: "engine", mode: "01", pid: "5E", unit: "L/h",  formula: "(A*256+B)/20",                       category: .engine,      min: nil, max: nil),
        PidDef(id: "demanded_torque",      displayName: "Demanded engine torque",ecu:"engine",  mode: "01", pid: "61", unit: "%",    formula: "A-125",                              category: .engine,      min: nil, max: nil),
        PidDef(id: "actual_torque",        displayName: "Actual engine torque",  ecu: "engine", mode: "01", pid: "62", unit: "%",    formula: "A-125",                              category: .engine,      min: nil, max: nil),
        PidDef(id: "engine_ref_torque",    displayName: "Engine reference torque",ecu:"engine", mode: "01", pid: "63", unit: "Nm",   formula: "A*256+B",                            category: .engine,      min: nil, max: nil),
    ]

    public static let byPid: [String: PidDef] = {
        var map: [String: PidDef] = [:]
        for p in all {
            map[p.pid.uppercased()] = p
        }
        return map
    }()

    public static let bitmaskPIDs: Set<String> = ["00", "20", "40", "60", "80", "A0", "C0"]

    public static func get(_ pidHex: String) -> PidDef? {
        let clean = pidHex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return byPid[clean]
    }
}

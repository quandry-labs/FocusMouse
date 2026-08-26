import Darwin
import Foundation
import IOKit

enum SystemThermalCondition: String, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

enum FanNoiseEstimate: String, Equatable, Sendable {
    case stopped
    case nearlySilent
    case quiet
    case audible
    case highAirflow

    static func estimate(rpm: Double, utilization: Double) -> FanNoiseEstimate {
        if rpm < 100 { return .stopped }
        switch utilization {
        case ..<0.25: return .nearlySilent
        case ..<0.45: return .quiet
        case ..<0.70: return .audible
        default: return .highAirflow
        }
    }
}

struct FanTelemetry: Equatable, Sendable {
    let count: Int
    let averageRPM: Double
    let maximumRPM: Double

    var utilization: Double {
        guard maximumRPM > 0 else { return 0 }
        return min(1, max(0, averageRPM / maximumRPM))
    }

    var noiseEstimate: FanNoiseEstimate {
        .estimate(rpm: averageRPM, utilization: utilization)
    }
}

struct HardwareTelemetrySample: Equatable, Sendable {
    enum PowerSource: String, Equatable, Sendable {
        case smcTotal
        case systemLoad
    }

    let thermalCondition: SystemThermalCondition
    let temperatureCelsius: Double?
    let temperatureSource: String?
    let systemPowerWatts: Double?
    let powerSource: PowerSource?
    let fan: FanTelemetry?

    static let placeholder = HardwareTelemetrySample(
        thermalCondition: .unknown,
        temperatureCelsius: nil,
        temperatureSource: nil,
        systemPowerWatts: nil,
        powerSource: nil,
        fan: nil
    )
}

/// Reads telemetry from the same native platform services macOS uses for
/// thermal management. SMC and IOHID are intentionally best-effort: sensor
/// keys differ by chip and unavailable values stay nil instead of being
/// inferred from CPU utilization.
final class HardwareTelemetryReader {
    private let smc = SMCClient()
    private let hid = HIDTemperatureReader()

    func sample() -> HardwareTelemetrySample {
        let smcTemperature = smc.readCPUTemperature()
        let temperature = smcTemperature ?? hid.readCPUTemperature()
        let smcPower = smc.readSystemPowerWatts()
        let registryPower = smcPower == nil ? Self.readSystemLoadWatts() : nil

        return HardwareTelemetrySample(
            thermalCondition: SystemThermalCondition(ProcessInfo.processInfo.thermalState),
            temperatureCelsius: temperature?.value,
            temperatureSource: temperature?.source,
            systemPowerWatts: smcPower ?? registryPower,
            powerSource: smcPower != nil ? .smcTotal : (registryPower != nil ? .systemLoad : nil),
            fan: smc.readFanTelemetry()
        )
    }

    private static func readSystemLoadWatts() -> Double? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "PowerTelemetryData" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue(),
            let telemetry = property as? [String: Any],
            let milliwatts = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue,
            milliwatts >= 0,
            milliwatts < 1_000_000
        else {
            return nil
        }

        return milliwatts / 1_000
    }
}

private struct TemperatureReading {
    let value: Double
    let source: String
}

// The SMC wire layout and read sequence are adapted from MacThrottle's
// MIT-licensed SMCReader and the exelban/Stats SMC implementation. See
// THIRD_PARTY_NOTICES.md for attribution.
private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCKeyData {
    struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var powerLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

private extension FourCharCode {
    init(smcKey: String) {
        precondition(smcKey.utf8.count == 4)
        self = smcKey.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

private final class SMCClient {
    private static let keyProbeRetryInterval: TimeInterval = 60
    private static let temperatureKeys = [
        // Package / proximity keys used on Intel and across several Apple
        // Silicon generations.
        "TCMz", "TCAD", "TC0D", "TC0P", "TC0H",
        // M1 family.
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
        "TC10", "TC11", "TC12", "TC13", "TC20", "TC21", "TC22", "TC23",
        "TC30", "TC31", "TC32", "TC33", "TC40", "TC41", "TC42", "TC43",
        "TC50", "TC51", "TC52", "TC53",
        // M2 family.
        "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp0f", "Tp0j",
        // M3 family.
        "Te05", "Te0L", "Te0P", "Te0S",
        "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
        "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
        // M4 family.
        "Te09", "Te0H", "Tp0V", "Tp0Y", "Tp0e"
    ]

    private var connection: io_connect_t = 0
    private var validTemperatureKeys: [String]?
    private var lastTemperatureProbe: Date?
    private var cachedFanCount: Int?

    init() {
        connect()
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func readCPUTemperature() -> TemperatureReading? {
        if let validTemperatureKeys, !validTemperatureKeys.isEmpty,
           let reading = hottestTemperature(from: validTemperatureKeys).reading
        {
            return reading
        }

        if let lastTemperatureProbe,
           validTemperatureKeys?.isEmpty == true,
           Date().timeIntervalSince(lastTemperatureProbe) < Self.keyProbeRetryInterval
        {
            return nil
        }

        let result = hottestTemperature(from: Self.temperatureKeys)
        validTemperatureKeys = result.validKeys
        lastTemperatureProbe = Date()
        return result.reading
    }

    func readSystemPowerWatts() -> Double? {
        guard let watts = readFloatingPoint(key: "PSTR"), watts >= 0, watts < 1_000 else {
            return nil
        }
        return watts
    }

    func readFanTelemetry() -> FanTelemetry? {
        let count: Int
        if let cachedFanCount {
            count = cachedFanCount
        } else if let fanCount = readUInt8(key: "FNum") {
            count = Int(fanCount)
            cachedFanCount = count
        } else {
            cachedFanCount = 0
            return nil
        }

        guard count > 0 else { return nil }
        var actualSpeeds: [Double] = []
        var maximumSpeeds: [Double] = []

        for index in 0..<count {
            guard let actual = readFloatingPoint(key: "F\(index)Ac"),
                  let maximum = readFloatingPoint(key: "F\(index)Mx"),
                  actual >= 0,
                  maximum > 0
            else {
                continue
            }
            actualSpeeds.append(actual)
            maximumSpeeds.append(maximum)
        }

        guard !actualSpeeds.isEmpty else { return nil }
        return FanTelemetry(
            count: actualSpeeds.count,
            averageRPM: actualSpeeds.reduce(0, +) / Double(actualSpeeds.count),
            maximumRPM: maximumSpeeds.reduce(0, +) / Double(maximumSpeeds.count)
        )
    }

    private func connect() {
        guard let matching = IOServiceMatching("AppleSMC") else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            return
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var openedConnection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &openedConnection) == kIOReturnSuccess else {
            return
        }
        connection = openedConnection
    }

    private func hottestTemperature(from keys: [String]) -> (reading: TemperatureReading?, validKeys: [String]) {
        var hottest: (key: String, value: Double)?
        var validKeys: [String] = []

        for key in keys {
            guard let value = readFloatingPoint(key: key), value > 10, value < 150 else { continue }
            validKeys.append(key)
            if hottest == nil || value > hottest!.value {
                hottest = (key, value)
            }
        }

        return (
            hottest.map { TemperatureReading(value: $0.value, source: "\($0.key) · SMC") },
            validKeys
        )
    }

    private func readUInt8(key: String) -> UInt8? {
        readRawValue(key: key)?.bytes.first
    }

    private func readFloatingPoint(key: String) -> Double? {
        guard let value = readRawValue(key: key) else { return nil }
        let bytes = value.bytes
        let type = value.dataType

        if bytes.count >= 4, type == FourCharCode(smcKey: "flt ") {
            let bits = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        }

        guard bytes.count >= 2 else { return nil }
        let unsigned = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        switch type {
        case FourCharCode(smcKey: "sp78"):
            return Double(Int16(bitPattern: unsigned)) / 256
        case FourCharCode(smcKey: "fpe2"):
            return Double(unsigned) / 4
        default:
            // Apple Silicon fan and power keys are four-byte floats. A few
            // older systems omit a useful type but retain fpe2-compatible data.
            return value.bytes.count == 2 ? Double(unsigned) / 4 : nil
        }
    }

    private func readRawValue(key: String) -> (bytes: [UInt8], dataType: UInt32)? {
        guard connection != 0 else { return nil }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = FourCharCode(smcKey: key)
        input.data8 = 9 // kSMCReadKeyInfo

        guard call(input: &input, output: &output) == kIOReturnSuccess else { return nil }
        let size = Int(output.keyInfo.dataSize)
        guard size > 0, size <= 32 else { return nil }
        let dataType = output.keyInfo.dataType

        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = 5 // kSMCReadBytes
        output = SMCKeyData()
        guard call(input: &input, output: &output) == kIOReturnSuccess else { return nil }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return (bytes, dataType)
    }

    private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(
            connection,
            2,
            &input,
            inputSize,
            &output,
            &outputSize
        )
    }
}

private final class HIDTemperatureReader {
    private typealias EventSystemClient = OpaquePointer
    private typealias ServiceClient = OpaquePointer
    private typealias Event = OpaquePointer
    private typealias Create = @convention(c) (CFAllocator?) -> EventSystemClient?
    private typealias SetMatching = @convention(c) (EventSystemClient, CFDictionary?) -> Void
    private typealias CopyServices = @convention(c) (EventSystemClient) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (ServiceClient, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (ServiceClient, Int64, Int32, Int64) -> Event?
    private typealias GetFloatValue = @convention(c) (Event, UInt32) -> Double
    private typealias Release = @convention(c) (OpaquePointer) -> Void

    private var create: Create?
    private var setMatching: SetMatching?
    private var copyServices: CopyServices?
    private var copyProperty: CopyProperty?
    private var copyEvent: CopyEvent?
    private var getFloatValue: GetFloatValue?
    private var release: Release?
    private var client: EventSystemClient?
    private var initialized = false

    deinit {
        if let release, let client {
            release(client)
        }
    }

    func readCPUTemperature() -> TemperatureReading? {
        initializeIfNeeded()
        guard let copyServices, let copyProperty, let copyEvent, let getFloatValue,
              let release, let client, let copiedServices = copyServices(client)
        else {
            return nil
        }

        let services = copiedServices.takeRetainedValue()
        var hottest: (product: String, value: Double)?

        for index in 0..<CFArrayGetCount(services) {
            let service = unsafeBitCast(
                CFArrayGetValueAtIndex(services, index),
                to: ServiceClient.self
            )
            let product = copyProperty(service, kIOHIDProductKey as CFString)?
                .takeRetainedValue() as? String ?? "PMU sensor"
            guard !(product.hasPrefix("PMU") && product.hasSuffix(" tcal")),
                  let event = copyEvent(service, 15, 0, 0)
            else {
                continue
            }

            let value = getFloatValue(event, 0x000f_0000)
            release(event)
            guard value > 10, value < 150 else { continue }
            if hottest == nil || value > hottest!.value {
                hottest = (product, value)
            }
        }

        return hottest.map { TemperatureReading(value: $0.value, source: "\($0.product) · HID") }
    }

    private func initializeIfNeeded() {
        guard !initialized else { return }
        initialized = true
        guard let handle = dlopen(nil, RTLD_NOW) else { return }

        create = loadSymbol(handle, "IOHIDEventSystemClientCreate", as: Create.self)
        setMatching = loadSymbol(handle, "IOHIDEventSystemClientSetMatching", as: SetMatching.self)
        copyServices = loadSymbol(handle, "IOHIDEventSystemClientCopyServices", as: CopyServices.self)
        copyProperty = loadSymbol(handle, "IOHIDServiceClientCopyProperty", as: CopyProperty.self)
        copyEvent = loadSymbol(handle, "IOHIDServiceClientCopyEvent", as: CopyEvent.self)
        getFloatValue = loadSymbol(handle, "IOHIDEventGetFloatValue", as: GetFloatValue.self)
        release = loadSymbol(handle, "CFRelease", as: Release.self)

        guard let create, let setMatching, let createdClient = create(kCFAllocatorDefault) else { return }
        client = createdClient
        let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        setMatching(createdClient, matching as CFDictionary)
    }

    private func loadSymbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}

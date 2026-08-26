import Foundation
import Testing
@testable import FocusMouse

@Suite("Hardware telemetry")
struct HardwareTelemetryTests {
    @Test("maps system thermal states")
    func mapsThermalStates() {
        #expect(SystemThermalCondition(.nominal) == .nominal)
        #expect(SystemThermalCondition(.fair) == .fair)
        #expect(SystemThermalCondition(.serious) == .serious)
        #expect(SystemThermalCondition(.critical) == .critical)
    }

    @Test("estimates fan acoustics from normalized speed")
    func estimatesFanNoise() {
        #expect(FanNoiseEstimate.estimate(rpm: 0, utilization: 0) == .stopped)
        #expect(FanNoiseEstimate.estimate(rpm: 1_000, utilization: 0.2) == .nearlySilent)
        #expect(FanNoiseEstimate.estimate(rpm: 2_000, utilization: 0.4) == .quiet)
        #expect(FanNoiseEstimate.estimate(rpm: 3_500, utilization: 0.6) == .audible)
        #expect(FanNoiseEstimate.estimate(rpm: 5_000, utilization: 0.9) == .highAirflow)
    }

    @Test("clamps fan utilization to a display-safe range")
    func clampsFanUtilization() {
        #expect(FanTelemetry(count: 1, averageRPM: 8_000, maximumRPM: 6_000).utilization == 1)
        #expect(FanTelemetry(count: 1, averageRPM: -10, maximumRPM: 6_000).utilization == 0)
        #expect(FanTelemetry(count: 2, averageRPM: 3_000, maximumRPM: 6_000).utilization == 0.5)
    }

    @Test("live sensor values are physically plausible when available")
    func validatesLiveSample() {
        let sample = HardwareTelemetryReader().sample()

        #expect(sample.thermalCondition != .unknown)
        if let temperature = sample.temperatureCelsius {
            #expect((10..<150).contains(temperature))
        }
        if let watts = sample.systemPowerWatts {
            #expect((0..<1_000).contains(watts))
        }
        if let fan = sample.fan {
            #expect(fan.count > 0)
            #expect(fan.averageRPM >= 0)
            #expect(fan.maximumRPM > 0)
            #expect((0...1).contains(fan.utilization))
        }
    }
}

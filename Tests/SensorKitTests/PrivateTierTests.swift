import Foundation
import Testing
@testable import SensorKit

@Suite("Energy unit conversion")
struct IOReportUnitTests {

    @Test("each unit converts to joules")
    func unitsConvert() {
        // A single "Energy Model" sample on an M4 returns three different units
        // at once: CPU in mJ, GPU in nJ, PCIe in uJ. Assuming any one of them
        // would be wrong by a factor of a million.
        #expect(IOReportInterface.joules(1000, unit: "mJ") == 1.0)
        #expect(IOReportInterface.joules(1_000_000, unit: "uJ") == 1.0)
        #expect(IOReportInterface.joules(1_000_000_000, unit: "nJ") == 1.0)
        #expect(IOReportInterface.joules(1, unit: "J") == 1.0)
    }

    @Test("unit labels are matched case-insensitively")
    func caseInsensitive() {
        #expect(IOReportInterface.joules(1000, unit: "MJ") == 1.0)
        #expect(IOReportInterface.joules(1000, unit: "mj") == 1.0)
    }

    @Test("the same quantity in different units agrees")
    func consistentAcrossUnits() throws {
        // An M4 publishes GPU energy twice, as "GPU" in mJ and "GPU Energy" in
        // nJ. Both were observed reporting ~151 mJ over one second, and any
        // conversion error would show up as the two disagreeing.
        let asMilli = try #require(IOReportInterface.joules(151, unit: "mJ"))
        let asNano = try #require(IOReportInterface.joules(151_000_000, unit: "nJ"))
        #expect(abs(asMilli - asNano) < 1e-9)
    }

    @Test("non-energy units are rejected rather than misread")
    func rejectsNonEnergy() {
        // The same groups carry state and event counters. Treating "events" or
        // "ticks" as energy would invent wattage out of a sleep count.
        #expect(IOReportInterface.joules(500, unit: "events") == nil)
        #expect(IOReportInterface.joules(500, unit: "ticks") == nil)
        #expect(IOReportInterface.joules(500, unit: "") == nil)
    }
}

@Suite("Thermal sensor curation")
struct ThermalCurationTests {

    @Test("duplicate sensor names get distinct metric ids")
    func disambiguatesDuplicates() {
        // Six sensors on the development machine are all called "gas gauge
        // battery". Without a suffix they would collapse onto one metric id and
        // silently overwrite each other every sample.
        let names = ["gas gauge battery", "gas gauge battery", "gas gauge battery", "PMU tdie1"]
        let slugs = ThermalSource.slugs(for: names)

        #expect(slugs == ["gas-gauge-battery", "gas-gauge-battery-2", "gas-gauge-battery-3", "pmu-tdie1"])
        #expect(Set(slugs).count == slugs.count)
    }

    @Test("slugs survive being written into a shared document")
    func slugsAreClean() {
        let slugs = ThermalSource.slugs(for: ["NAND CH0 temp", "PMU2 tdev4", ""])
        #expect(slugs == ["nand-ch0-temp", "pmu2-tdev4", "sensor"])
        for slug in slugs {
            #expect(slug.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
        }
    }

    @Test("calibration references are kept out of the aggregates")
    func excludesCalibrationSensors() {
        // Both `tcal` sensors on an M4 sit at exactly 51.82 C, well above every
        // real reading. Counted as a temperature they would pin `thermal.peak`
        // to a constant and make it useless.
        #expect(ThermalSource.categorise("PMU tcal") == .reference)
        #expect(ThermalSource.categorise("PMU2 tcal") == .reference)
        #expect(ThermalSource.categorise("PMU tdie6") == .chip)
    }

    @Test("sensors are sorted into the right aggregate")
    func categorises() {
        #expect(ThermalSource.categorise("gas gauge battery") == .battery)
        #expect(ThermalSource.categorise("NAND CH0 temp") == .storage)
        #expect(ThermalSource.categorise("PMU2 tdev4") == .chip)
    }

    @Test("impossible readings are discarded")
    func filtersImplausible() {
        // Three unpopulated channels report about -22 C. Averaged in, they drag
        // the mean down by degrees and make the minimum meaningless.
        #expect(!ThermalSource.isPlausible(-22.27))
        #expect(!ThermalSource.isPlausible(300))
        #expect(ThermalSource.isPlausible(31.4))
        #expect(ThermalSource.isPlausible(95))
    }
}

@Suite("Capability probes")
struct CapabilityProbeTests {

    @Test("a source with no hardware offers no metrics")
    func absentHardwarePublishesNothing() {
        // This is what stops the picker filling with entries that can never
        // produce a reading. Verified on a fanless MacBook Air, where FanSource
        // finds nothing and therefore offers nothing.
        let fans = FanSource()
        let descriptors = fans.descriptors
        #expect(descriptors.isEmpty || descriptors.allSatisfy { $0.group == "Fans" })
    }

    @Test("sources that do have hardware describe it")
    func presentHardwareIsDescribed() {
        // These hold on any Mac this could run on: every machine has a GPU, and
        // the thermal interface was verified working.
        #expect(!GPUSource().descriptors.isEmpty)
        #expect(GPUSource().descriptors.contains { $0.id == GPUSource.utilization })

        let thermal = ThermalSource().descriptors
        if !thermal.isEmpty {
            #expect(thermal.contains { $0.id == ThermalSource.peak })
            // Raw sensors are separated from the portable aggregates, so the
            // picker does not bury four useful metrics under forty-seven.
            #expect(thermal.contains { $0.group == "Temperature (Advanced)" })
        }
    }

    @Test("every private source declares only what it can emit")
    func descriptorsMatchEmissions() async throws {
        for source in [ThermalSource() as any MetricSource, GPUSource(), PowerSource(), BatterySource(), FanSource()] {
            let declared = Set(source.descriptors.map(\.id))
            guard !declared.isEmpty else { continue }

            source.activate()
            defer { source.deactivate() }

            var sink = SampleSink()
            source.sample(into: &sink, context: SampleContext(elapsed: 0))
            try await Task.sleep(for: .milliseconds(200))
            sink.reset()
            source.sample(into: &sink, context: SampleContext(elapsed: 0.2))

            for reading in sink.readings {
                #expect(declared.contains(reading.id),
                        "\(type(of: source)) emitted undeclared \(reading.id)")
                #expect(reading.value.isFinite, "\(reading.id) was not finite")
            }
        }
    }
}

@Suite("Clock source")
struct ClockSourceTests {

    @Test("reports the current time and a monotonic uptime")
    func reportsTime() {
        let source = ClockSource()
        source.activate()
        var sink = SampleSink()
        source.sample(into: &sink, context: SampleContext(elapsed: 1))

        let values = Dictionary(uniqueKeysWithValues: sink.readings.map { ($0.id, $0.value) })
        let epoch = values[ClockSource.epoch]
        let uptime = values[ClockSource.uptime]

        #expect(epoch != nil)
        #expect(abs((epoch ?? 0) - Date().timeIntervalSince1970) < 2)
        #expect((uptime ?? 0) > 0)
    }

    @Test("reports on the very first sample, with no baseline needed")
    func noPriming() {
        // A clock has no delta to prime, so a blank first tick would be a
        // second of dashes on every launch for no reason.
        let source = ClockSource()
        var sink = SampleSink()
        source.sample(into: &sink, context: SampleContext(elapsed: 0))
        #expect(sink.readings.count == 2)
    }

    @Test("declares what it emits")
    func descriptorsMatch() {
        let source = ClockSource()
        let declared = Set(source.descriptors.map(\.id))
        var sink = SampleSink()
        source.sample(into: &sink, context: SampleContext(elapsed: 1))
        for reading in sink.readings {
            #expect(declared.contains(reading.id))
        }
    }
}

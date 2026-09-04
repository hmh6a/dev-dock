import XCTest
@testable import DevDockCore

final class ByteFormatTests: XCTestCase {

    func testStorageUsesDecimalUnitsLikeFinder() {
        XCTAssertEqual(ByteFormat.storage(0), "0 B")
        XCTAssertEqual(ByteFormat.storage(512), "512 B")
        XCTAssertEqual(ByteFormat.storage(994_000_000), "994 MB")
        XCTAssertEqual(ByteFormat.storage(494_384_795_648), "494 GB")
        XCTAssertEqual(ByteFormat.storage(2_000_000_000_000), "2 TB")
    }

    func testMemoryUsesBinaryUnitsSoInstalledRamReadsAsAdvertised() {
        XCTAssertEqual(ByteFormat.memory(25_769_803_776), "24 GB")
        XCTAssertEqual(ByteFormat.memory(1_073_741_824), "1 GB")
        XCTAssertEqual(ByteFormat.memory(1_048_576), "1 MB")
        XCTAssertEqual(ByteFormat.memory(6_120_000_000), "5.7 GB")
    }

    func testPercentDropsDecimalWhenLarge() {
        XCTAssertEqual(PercentFormat.short(0), "0%")
        XCTAssertEqual(PercentFormat.short(4.26), "4.3%")
        XCTAssertEqual(PercentFormat.short(8), "8%")
        XCTAssertEqual(PercentFormat.short(47.3), "47%")
    }
}

final class CPUUsageTests: XCTestCase {

    func testUsageIsTheDeltaBetweenTwoReadings() {
        let first = CPUTicks(user: 1000, system: 500, idle: 8000, nice: 0)
        // 200 more user ticks, 100 system, 700 idle — 1000 ticks in the interval.
        let second = CPUTicks(user: 1200, system: 600, idle: 8700, nice: 0)

        let usage = CPUUsage.between(first, and: second)
        XCTAssertEqual(usage.userPercent, 20, accuracy: 0.001)
        XCTAssertEqual(usage.systemPercent, 10, accuracy: 0.001)
        XCTAssertEqual(usage.idlePercent, 70, accuracy: 0.001)
        XCTAssertEqual(usage.usedPercent, 30, accuracy: 0.001)
        XCTAssertEqual(usage.usedLabel, "30%")
    }

    func testNiceTimeCountsAsUserSoThePartsSumTo100() {
        let usage = CPUUsage.between(
            CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
            and: CPUTicks(user: 250, system: 250, idle: 250, nice: 250)
        )
        XCTAssertEqual(usage.userPercent, 50, accuracy: 0.001)
        XCTAssertEqual(usage.userPercent + usage.systemPercent + usage.idlePercent, 100, accuracy: 0.001)
    }

    func testFirstSampleFallsBackToAverageSinceBoot() {
        let usage = CPUUsage.between(nil, and: CPUTicks(user: 100, system: 100, idle: 800, nice: 0))
        XCTAssertEqual(usage.usedPercent, 20, accuracy: 0.001)
    }

    func testIdenticalReadingsReportIdle() {
        let ticks = CPUTicks(user: 10, system: 10, idle: 10, nice: 10)
        let usage = CPUUsage.between(ticks, and: ticks)
        XCTAssertEqual(usage.idlePercent, 100)
        XCTAssertEqual(usage.usedPercent, 0)
    }
}

final class MemoryUsageTests: XCTestCase {

    private let memory = MemoryUsage(
        totalBytes: 16_000_000_000,
        appBytes: 6_000_000_000,
        wiredBytes: 2_000_000_000,
        compressedBytes: 1_000_000_000,
        cachedBytes: 3_000_000_000,
        freeBytes: 4_000_000_000
    )

    func testUsedIsAppPlusWiredPlusCompressed() {
        XCTAssertEqual(memory.usedBytes, 9_000_000_000)
        XCTAssertEqual(memory.usedPercent, 56.25, accuracy: 0.001)
    }

    func testCachedMemoryIsNotCountedAsUsed() {
        XCTAssertLessThan(memory.usedBytes, memory.totalBytes - memory.cachedBytes + 1)
    }

    func testPressureLevelMapsKernelValues() {
        XCTAssertEqual(MemoryPressureLevel(rawLevel: 1), .normal)
        XCTAssertEqual(MemoryPressureLevel(rawLevel: 2), .warning)
        XCTAssertEqual(MemoryPressureLevel(rawLevel: 4), .critical)
        XCTAssertEqual(MemoryPressureLevel(rawLevel: 99), .normal)
    }
}

final class GPUPerformanceStatisticsTests: XCTestCase {

    /// Captured from an Apple Silicon `AGXAccelerator` entry.
    private let appleSilicon: [String: Any] = [
        "Device Utilization %": 11,
        "Renderer Utilization %": 10,
        "Tiler Utilization %": 8,
        "In use system memory": 1_345_241_088,
        "Alloc system memory": 4_787_486_720
    ]

    func testReadsUtilizationAndMemory() {
        let usage = GPUPerformanceStatistics.usage(name: "Apple M4 Pro GPU", statistics: appleSilicon)
        XCTAssertEqual(usage.utilizationPercent, 11)
        XCTAssertEqual(usage.rendererPercent, 10)
        XCTAssertEqual(usage.tilerPercent, 8)
        XCTAssertEqual(usage.inUseMemoryBytes, 1_345_241_088)
        XCTAssertEqual(usage.utilizationLabel, "11%")
    }

    func testMissingKeysDegradeToZeroRatherThanFailing() {
        let usage = GPUPerformanceStatistics.usage(name: "GPU", statistics: [:])
        XCTAssertEqual(usage.utilizationPercent, 0)
        XCTAssertNil(usage.rendererPercent)
        XCTAssertNil(usage.inUseMemoryBytes)
    }

    func testUtilizationIsClampedToAHundred() {
        let usage = GPUPerformanceStatistics.usage(name: "GPU", statistics: ["Device Utilization %": 250])
        XCTAssertEqual(usage.utilizationPercent, 100)
    }
}

final class ThermalSensorClassifierTests: XCTestCase {

    func testNamesAreGroupedByHardware() {
        XCTAssertEqual(ThermalSensorClassifier.group(for: "GPU MTR Temp Sensor1"), .gpu)
        XCTAssertEqual(ThermalSensorClassifier.group(for: "pACC MTR Temp Sensor3"), .cpu)
        XCTAssertEqual(ThermalSensorClassifier.group(for: "eACC MTR Temp Sensor1"), .cpu)
        XCTAssertEqual(ThermalSensorClassifier.group(for: "PMU tdie8"), .soc)
        XCTAssertEqual(ThermalSensorClassifier.group(for: "PMU tdev4"), .soc)
        XCTAssertEqual(ThermalSensorClassifier.group(for: "NAND CH0 temp"), .storage)
        XCTAssertEqual(ThermalSensorClassifier.group(for: "gas gauge battery"), .battery)
    }

    /// `PMU tcal` sits at a fixed value while the machine heats up, so it must
    /// not be treated as a die sensor — it would pin the headline temperature.
    func testCalibrationSensorIsNotADieSensor() {
        XCTAssertEqual(ThermalSensorClassifier.group(for: "PMU tcal"), .other)
    }

    func testHeadlineTemperaturesTakeTheHottestSensorInEachGroup() {
        let snapshot = ThermalSensorClassifier.summarize([
            ("pACC MTR Temp Sensor1", 60),
            ("pACC MTR Temp Sensor2", 72),
            ("GPU MTR Temp Sensor1", 55)
        ])
        XCTAssertEqual(snapshot.cpu, 72)
        XCTAssertEqual(snapshot.gpu, 55)
        XCTAssertFalse(snapshot.isSharedDie)
    }

    func testRepeatedSensorNamesAreAveragedIntoOneReading() {
        let snapshot = ThermalSensorClassifier.summarize([
            ("gas gauge battery", 30),
            ("gas gauge battery", 32),
            ("PMU tdie1", 44)
        ])
        XCTAssertEqual(snapshot.readings.count, 2)
        XCTAssertEqual(snapshot.readings.first(where: { $0.sensor == "gas gauge battery" })?.celsius, 31)
    }

    /// M3/M4 chips name no CPU or GPU sensor — both figures fall back to the die.
    func testDieSensorsStandInWhenNoCpuOrGpuSensorIsNamed() {
        let snapshot = ThermalSensorClassifier.summarize([
            ("PMU tdie1", 44), ("PMU tdie8", 47), ("PMU tcal", 52), ("gas gauge battery", 30)
        ])
        XCTAssertEqual(snapshot.cpu, 47)
        XCTAssertEqual(snapshot.gpu, 47)
        XCTAssertTrue(snapshot.isSharedDie)
    }

    func testImplausibleReadingsAreDropped() {
        let snapshot = ThermalSensorClassifier.summarize([
            ("PMU tdie1", 0), ("PMU tdie2", -127), ("PMU tdie3", 4000), ("PMU tdie4", 41)
        ])
        XCTAssertEqual(snapshot.readings.map(\.sensor), ["PMU tdie4"])
        XCTAssertEqual(snapshot.cpu, 41)
    }

    func testNoSensorsYieldsAnEmptySnapshot() {
        let snapshot = ThermalSensorClassifier.summarize([])
        XCTAssertEqual(snapshot, .empty)
        XCTAssertFalse(snapshot.isAvailable)
        XCTAssertNil(snapshot.cpu)
    }
}

final class VolumeUsageTests: XCTestCase {

    func testUsedIsWhatIsNotAvailable() {
        let volume = VolumeUsage(
            name: "Macintosh HD", path: "/",
            totalBytes: 494_384_795_648, freeBytes: 24_000_000_000, isRoot: true
        )
        XCTAssertEqual(volume.usedBytes, 470_384_795_648)
        XCTAssertEqual(volume.usedPercent, 95.145, accuracy: 0.01)
    }

    func testEmptyVolumeDoesNotDivideByZero() {
        let volume = VolumeUsage(name: "Ghost", path: "/x", totalBytes: 0, freeBytes: 0, isRoot: false)
        XCTAssertEqual(volume.usedFraction, 0)
    }
}

final class SystemSnapshotTests: XCTestCase {

    private func snapshot(volumes: [VolumeUsage]) -> SystemSnapshot {
        SystemSnapshot(
            cpu: CPUUsage(userPercent: 10, systemPercent: 5, idlePercent: 85),
            memory: MemoryUsage(
                totalBytes: 8, appBytes: 1, wiredBytes: 1,
                compressedBytes: 1, cachedBytes: 1, freeBytes: 4
            ),
            gpus: [GPUUsage(name: "GPU", utilizationPercent: 3)],
            volumes: volumes,
            thermal: .empty,
            hardware: .unknown
        )
    }

    func testRootVolumeLeadsAndTheRestFollow() {
        let root = VolumeUsage(name: "Macintosh HD", path: "/", totalBytes: 100, freeBytes: 50, isRoot: true)
        let external = VolumeUsage(name: "Backup", path: "/Volumes/Backup", totalBytes: 100, freeBytes: 10, isRoot: false)

        let snapshot = self.snapshot(volumes: [external, root])
        XCTAssertEqual(snapshot.rootVolume, root)
        XCTAssertEqual(snapshot.otherVolumes, [external])
    }

    func testWithoutARootVolumeTheFirstOneStandsIn() {
        let external = VolumeUsage(name: "Backup", path: "/Volumes/Backup", totalBytes: 100, freeBytes: 10, isRoot: false)
        let snapshot = self.snapshot(volumes: [external])
        XCTAssertEqual(snapshot.rootVolume, external)
        XCTAssertTrue(snapshot.otherVolumes.isEmpty)
    }
}

final class NetworkThroughputTests: XCTestCase {

    func testRateIsTheDeltaOverTheElapsedTime() {
        let throughput = NetworkThroughput.between(
            NetworkTicks(receivedBytes: 1_000_000, sentBytes: 500_000),
            and: NetworkTicks(receivedBytes: 3_400_000, sentBytes: 700_000),
            elapsed: 2
        )
        XCTAssertEqual(throughput.downloadBytesPerSecond, 1_200_000, accuracy: 0.001)
        XCTAssertEqual(throughput.uploadBytesPerSecond, 100_000, accuracy: 0.001)
        XCTAssertEqual(throughput.combinedBytesPerSecond, 1_300_000, accuracy: 0.001)
        XCTAssertEqual(throughput.downloadLabel, "1.2 MB/s")
        XCTAssertEqual(throughput.uploadLabel, "100 KB/s")
    }

    /// The first sample has no predecessor: reporting the average since the
    /// interface came up would say nothing about the network right now.
    func testFirstSampleReportsIdleButKeepsTheTotals() {
        let throughput = NetworkThroughput.between(
            nil,
            and: NetworkTicks(receivedBytes: 4_000_000_000, sentBytes: 50_000_000),
            elapsed: 2
        )
        XCTAssertEqual(throughput.downloadBytesPerSecond, 0)
        XCTAssertEqual(throughput.totalReceivedBytes, 4_000_000_000)
        XCTAssertEqual(throughput.totalSentBytes, 50_000_000)
    }

    /// A reset interface (or a wrapped 32-bit counter) must not read as a
    /// negative rate.
    func testCountersGoingBackwardsReadAsZero() {
        let throughput = NetworkThroughput.between(
            NetworkTicks(receivedBytes: 900, sentBytes: 900),
            and: NetworkTicks(receivedBytes: 100, sentBytes: 100),
            elapsed: 2
        )
        XCTAssertEqual(throughput.downloadBytesPerSecond, 0)
        XCTAssertEqual(throughput.uploadBytesPerSecond, 0)
    }

    func testZeroElapsedTimeDoesNotDivideByZero() {
        let throughput = NetworkThroughput.between(
            NetworkTicks(receivedBytes: 0, sentBytes: 0),
            and: NetworkTicks(receivedBytes: 500, sentBytes: 500),
            elapsed: 0
        )
        XCTAssertEqual(throughput.combinedBytesPerSecond, 0)
    }

    func testOnlyRealLinksAreCounted() {
        XCTAssertTrue(NetworkInterfaceFilter.countsTowardThroughput("en0"))
        XCTAssertTrue(NetworkInterfaceFilter.countsTowardThroughput("eth0"))
        XCTAssertTrue(NetworkInterfaceFilter.countsTowardThroughput("pdp_ip0"))
        XCTAssertFalse(NetworkInterfaceFilter.countsTowardThroughput("lo0"))
        XCTAssertFalse(NetworkInterfaceFilter.countsTowardThroughput("bridge0"))
        XCTAssertFalse(NetworkInterfaceFilter.countsTowardThroughput("gif0"))
        // AirDrop and the low-latency link start with "en"-ish names but never
        // carry internet traffic.
        XCTAssertFalse(NetworkInterfaceFilter.countsTowardThroughput("awdl0"))
        XCTAssertFalse(NetworkInterfaceFilter.countsTowardThroughput("llw0"))
    }

    /// A VPN tunnel carries the same bytes the physical link already counted.
    func testTunnelsAreExcludedSoVpnBytesAreNotCountedTwice() {
        XCTAssertFalse(NetworkInterfaceFilter.countsTowardThroughput("utun4"))
        let total = NetworkInterfaceFilter.total([
            ("en0", NetworkTicks(receivedBytes: 1000, sentBytes: 100)),
            ("utun4", NetworkTicks(receivedBytes: 900, sentBytes: 90)),
            ("lo0", NetworkTicks(receivedBytes: 5000, sentBytes: 5000))
        ])
        XCTAssertEqual(total, NetworkTicks(receivedBytes: 1000, sentBytes: 100))
    }

    func testEveryCountedInterfaceAddsUp() {
        let total = NetworkInterfaceFilter.total([
            ("en0", NetworkTicks(receivedBytes: 1000, sentBytes: 100)),
            ("en5", NetworkTicks(receivedBytes: 250, sentBytes: 25))
        ])
        XCTAssertEqual(total, NetworkTicks(receivedBytes: 1250, sentBytes: 125))
    }

    func testRateLabelsUseNetworkingUnits() {
        XCTAssertEqual(ByteFormat.rate(0), "0 B/s")
        XCTAssertEqual(ByteFormat.rate(840_000), "840 KB/s")
        XCTAssertEqual(ByteFormat.rate(12_400_000), "12.4 MB/s")
    }
}

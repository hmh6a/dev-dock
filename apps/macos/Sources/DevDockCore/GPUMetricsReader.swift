import Foundation
import IOKit

/// Reads live GPU utilization from the IORegistry.
///
/// Every graphics driver on macOS publishes a `PerformanceStatistics` dictionary
/// on its `IOAccelerator` service — the same numbers Activity Monitor's GPU
/// history graph draws. Reading the registry directly avoids shelling out to
/// `ioreg` (a fork per poll) and needs no special privileges.
public struct GPUMetricsReader: Sendable {

    public init() {}

    /// Every graphics device, with its current utilization.
    ///
    /// Returns an empty array rather than throwing when the registry can't be
    /// read — a Mac without a reported GPU is a missing card in the UI, not an error.
    public func scan() -> [GPUUsage] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var usages: [GPUUsage] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let statistics = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            usages.append(GPUPerformanceStatistics.usage(
                name: name(of: service),
                statistics: statistics
            ))
        }
        return usages
    }

    /// A readable name for the device.
    ///
    /// Discrete and Intel GPUs publish a `model` on the PCI device that owns the
    /// accelerator (`AMD Radeon Pro 5500M`). Apple Silicon publishes none — the
    /// accelerator is just `AGXAcceleratorG16X` — so the chip name stands in,
    /// which is also how the GPU is marketed ("Apple M4 Pro GPU").
    private func name(of service: io_service_t) -> String {
        var parent: io_registry_entry_t = 0
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            if let model = IORegistryEntryCreateCFProperty(
                parent, "model" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() {
                if let string = model as? String, !string.isEmpty { return string }
                // IOKit hands PCI model names over as NUL-terminated bytes.
                if let data = model as? Data {
                    let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { return text }
                }
            }
        }
        if let chip = HostMetricsSampler.sysctlString("machdep.cpu.brand_string") {
            return "\(chip) GPU"
        }
        return "GPU"
    }
}

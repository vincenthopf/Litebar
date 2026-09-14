import AppKit
import Darwin

private func cpuSeconds() -> Double {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0, "CPU measurement failed")
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

private func physicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let capacity = Int(count)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS && info.phys_footprint > 0, "Memory measurement failed")
    return info.phys_footprint
}

@MainActor
func benchmarkNative(_ controller: Controller) {
    let warmup = Timer(timeInterval: 1, repeats: false) { _ in
        MainActor.assumeIsolated {
            let started = DispatchTime.now().uptimeNanoseconds
            let cpu = cpuSeconds()
            let scans = controller.inventory.scans
            let sample = Timer(timeInterval: 5, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
                    let report: [String: Any] = [
                        "mode": "default settings, isolated preferences, hosted runner permissions",
                        "sample_seconds": seconds,
                        "cpu_percent_of_one_core": max(0, cpuSeconds() - cpu) / seconds * 100,
                        "physical_footprint_bytes": physicalFootprint(),
                        "inventory_scans_during_sample": controller.inventory.scans - scans,
                        "application_timers_at_end": controller.activeTimerCount,
                        "synthetic_event_taps_at_end": Delivery.activeTaps,
                        "mouse_movement_monitor_at_end": controller.monitorsMovement
                    ]
                    do {
                        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        print(String(decoding: data, as: UTF8.self))
                    } catch { preconditionFailure(error.localizedDescription) }
                    precondition(controller.activeTimerCount == 0, "Default idle runtime scheduled a timer")
                    precondition(!controller.monitorsMovement, "Default idle runtime monitors mouse movement")
                    precondition(Delivery.activeTaps == 0, "Default idle runtime installed an input tap")
                    controller.stop()
                    NSApp.terminate(nil)
                }
            }
            RunLoop.main.add(sample, forMode: .common)
        }
    }
    RunLoop.main.add(warmup, forMode: .common)
}

import AppKit

MainActor.assumeIsolated {
    #if LITEBAR_VALIDATION
    let selfTest = CommandLine.arguments.contains("--self-test")
    #else
    let selfTest = false
    #endif
    let benchmark = CommandLine.arguments.contains("--benchmark-idle")
    let application = NSApplication.shared
    let controller = Controller(validation: selfTest, benchmark: benchmark)
    #if LITEBAR_VALIDATION
    if selfTest { controller.onValidation = { value in _ = Task { @MainActor in await validateNative(value) } } }
    #endif
    if benchmark { controller.onBenchmark = { value in MainActor.assumeIsolated { benchmarkNative(value) } } }
    application.delegate = controller
    withExtendedLifetime(controller) { application.run() }
}

import AppKit

MainActor.assumeIsolated {
    let selfTest = CommandLine.arguments.contains("--self-test")
    let benchmark = CommandLine.arguments.contains("--benchmark-idle")
    let application = NSApplication.shared
    let controller = Controller(validation: selfTest, benchmark: benchmark)
    if selfTest { controller.onValidation = { value in _ = Task { @MainActor in await validateNative(value) } } }
    if benchmark { controller.onBenchmark = { value in MainActor.assumeIsolated { benchmarkNative(value) } } }
    application.delegate = controller
    withExtendedLifetime(controller) { application.run() }
}

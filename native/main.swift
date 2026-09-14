import AppKit

MainActor.assumeIsolated {
    let selfTest = CommandLine.arguments.contains("--self-test")
    let application = NSApplication.shared
    let controller = Controller(validation: selfTest)
    if selfTest {
        controller.onValidation = { value in MainActor.assumeIsolated { validateNative(value) } }
    }
    application.delegate = controller
    withExtendedLifetime(controller) { application.run() }
}

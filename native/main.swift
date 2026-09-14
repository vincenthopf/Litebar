import AppKit

let arguments = CommandLine.arguments
let selfTest = arguments.contains("--self-test")
let application = NSApplication.shared
let controller = Controller(validation: selfTest)
if selfTest { controller.onValidation = validateNative }
application.delegate = controller
application.run()

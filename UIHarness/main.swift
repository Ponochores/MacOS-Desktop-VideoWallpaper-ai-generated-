import Cocoa

let app = NSApplication.shared
let harness = Harness()
app.delegate = harness
app.setActivationPolicy(.regular)
app.run()

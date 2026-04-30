import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
zoomItDebugLog("Starting ZoomItForMacApp with accessory activation policy")
withExtendedLifetime(delegate) {
    app.run()
}

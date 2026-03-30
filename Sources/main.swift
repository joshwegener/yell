import AppKit

guard let singleInstanceLock = SingleInstanceLock() else {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // No Dock icon
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(singleInstanceLock) {
    app.run()
}

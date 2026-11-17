import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // LSUIElement와 같은 효과(번들 없이 실행해도 Dock 없음)
app.run()

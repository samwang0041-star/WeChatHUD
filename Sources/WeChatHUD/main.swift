import AppKit
import Darwin

// Line-buffer stdout so `tee`/`tail -f` sees prints immediately.
setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

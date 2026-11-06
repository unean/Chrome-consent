import AppKit
import ApplicationServices
import Foundation
import ImageIO

var arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--wait-for-exit", let previous = Int32(arguments[2]), previous > 1 {
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    while kill(previous, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.1) }
    guard kill(previous, 0) != 0 else { exit(2) }
    arguments = [arguments[0]]
}
if arguments.count == 2, arguments[1] == "--permission-probe" {
    FileHandle.standardOutput.write(try JSONEncoder().encode(PermissionSnapshot.current())); exit(0)
}
if arguments.contains("--diagnose") {
    let info: [String: Any] = ["lockState": Int(cc_lock_state()), "accessibility": AXIsProcessTrusted(),
                              "screenCapture": CGPreflightScreenCaptureAccess(), "installed": cc_install_ready() == 1,
                              "candidateCount": candidates().count, "version": Product.version]
    print(String(data: try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}
if arguments == [arguments[0], "--login-diagnose"] {
    let snapshot = loginScreenSnapshot()
    let info: [String: Any] = ["lockState": Int(cc_lock_state()), "loginPID": cc_login_pid(),
                              "snapshotAvailable": snapshot != nil, "elementCount": snapshot?.elements.count ?? 0,
                              "passwordFieldPresent": snapshot?.password != nil,
                              "wakeTargetPresent": snapshot?.wakeTarget != nil, "version": Product.version,
                              "elements": snapshot?.elements.map {
                                  ["role": $0.role, "identifier": $0.identifier, "hasFrame": $0.frame != nil,
                                   "enabled": $0.enabled] as [String: Any]
                              } ?? []]
    print(String(data: try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}
if arguments == [arguments[0], "--dialog-diagnose"] {
    let snapshot = candidateSnapshot()
    let info: [String: Any] = ["version": Product.version, "lockState": cc_lock_state(),
                              "windowQueryAvailable": snapshot != nil,
                              "dialogs": (snapshot ?? []).map { authorizationDiagnostics($0, presence: authorizationPresence($0)) }]
    print(String(data: try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]), encoding: .utf8)!)
    exit(0)
}
let application = NSApplication.shared
var retained: AnyObject?
if arguments.count == 3, arguments[1] == "--render-menu-icon" {
    let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    configureMenuBarButton(button)
    guard let data = button.image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
          let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: URL(fileURLWithPath: arguments[2]))
    exit(0)
}
if arguments.count == 3, ["--render-preview", "--render-permission-preview", "--render-screen-preview", "--render-ready-preview", "--render-shield-preview", "--render-menu-preview"].contains(arguments[1]) {
    application.appearance = NSAppearance(named: .aqua)
    let previewWindow: NSWindow
    if arguments[1] == "--render-menu-preview" {
        previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 72), styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: previewWindow.frame)
        for index in 0..<2 {
            let panel = NSView(frame: NSRect(x: CGFloat(index) * 120, y: 0, width: 120, height: 72))
            panel.appearance = NSAppearance(named: index == 0 ? .aqua : .darkAqua)
            panel.wantsLayer = true
            panel.layer?.backgroundColor = NSColor(calibratedWhite: index == 0 ? 0.96 : 0.12, alpha: 1).cgColor
            let button = NSButton(frame: NSRect(x: 48, y: 24, width: 24, height: 24))
            button.isBordered = false
            configureMenuBarButton(button)
            panel.addSubview(button); root.addSubview(panel)
        }
        previewWindow.contentView = root
        retained = previewWindow
    } else if arguments[1] == "--render-shield-preview" {
        guard let screen = NSScreen.screens.first, let image = LockShield.wallpaper(for: screen) else { exit(1) }
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        previewWindow = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        let view = LockShieldView(frame: bounds, image: image, displayBounds: bounds)
        view.passwordFrame = CGRect(x: 600, y: 760, width: 240, height: 28)
        previewWindow.contentView = view
        retained = previewWindow
    } else if arguments[1] == "--render-preview" {
        let delegate = AppDelegate(); retained = delegate
        delegate.buildWindow(preview: true); previewWindow = delegate.window
    } else {
        let snapshot = PermissionSnapshot(accessibility: arguments[1] != "--render-permission-preview", screenCapture: arguments[1] == "--render-ready-preview")
        let guide = PermissionGuideController(readPermissions: { snapshot }); retained = guide; previewWindow = guide.window
    }
    guard let view = previewWindow.contentView else { exit(1) }
    view.layoutSubtreeIfNeeded()
    previewWindow.displayIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let rectangle = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    guard let context = CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bitsPerComponent: 8,
        bytesPerRow: bitmap.pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let cgImage = bitmap.cgImage else { exit(1) }
    context.setFillColor(CGColor(gray: 0.96, alpha: 1)); context.fill(rectangle); context.draw(cgImage, in: rectangle)
    guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: arguments[2]) as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
    func checkLayout(_ parent: NSView) -> Bool {
        var valid = true
        for item in parent.subviews where !item.isHidden {
            let rect = item.convert(item.bounds, to: view)
            let fits = view.bounds.insetBy(dx: -1, dy: -1).contains(rect)
            print("layout \(type(of: item)) \(rect) fits=\(fits)")
            valid = checkLayout(item) && fits && valid
        }
        return valid
    }
    exit(checkLayout(view) ? 0 : 1)
} else if arguments.count == 5, arguments[1] == "--guardian", let parent = Int32(arguments[2]),
   let windowID = UInt32(arguments[3]), let pid = Int32(arguments[4]),
   let candidate = candidates().first(where: { $0.windowID == windowID && $0.pid == pid }) {
    application.setActivationPolicy(.prohibited)
    let guardian = Guardian(parent: parent, target: candidate); retained = guardian
    guardian.start()
} else if arguments.count == 3, arguments[1] == "--watchdog", let parent = Int32(arguments[2]) {
    application.setActivationPolicy(.prohibited)
    let watchdog = Watchdog(parent: parent); retained = watchdog
    watchdog.start()
} else if arguments.count == 1 || arguments.dropFirst().allSatisfy({ $0.hasPrefix("-psn_") }) {
    if Bundle.main.bundlePath == Product.installedApp {
        let lockURL = Product.logURL.deletingLastPathComponent().appendingPathComponent("app.lock")
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let singletonFD = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard singletonFD >= 0, flock(singletonFD, LOCK_EX | LOCK_NB) == 0 else {
            NSRunningApplication.runningApplications(withBundleIdentifier: "local.chromeconsent.app")
                .first(where: { $0.processIdentifier != getpid() && $0.bundleURL?.path == Product.installedApp })?.activate(options: [.activateAllWindows])
            exit(0)
        }
        _ = fcntl(singletonFD, F_SETFD, FD_CLOEXEC)
    }
    let delegate = AppDelegate(); retained = delegate; application.delegate = delegate
} else {
    fputs("Unknown arguments\n", stderr); exit(2)
}
application.run()

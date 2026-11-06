import AppKit
import ScreenCaptureKit

func shieldBannerFrame(in bounds: CGRect, display: CGRect, password: CGRect?) -> CGRect {
    let marginX = min(20, bounds.width / 2), marginY = min(20, bounds.height / 2)
    let width = min(420, max(0, bounds.width - 2 * marginX)), height = min(72, max(0, bounds.height - 2 * marginY))
    var center = bounds.midX, bottom = bounds.minY + bounds.height * 0.2
    if let password, display.contains(CGPoint(x: password.midX, y: password.midY)) {
        center = bounds.minX + password.midX - display.minX
        bottom = bounds.maxY - (password.minY - display.minY) + 18
    }
    return CGRect(x: min(max(center - width / 2, bounds.minX + marginX), bounds.maxX - width - marginX),
                  y: min(max(bottom, bounds.minY + marginY), bounds.maxY - height - marginY), width: width, height: height)
}

struct ShieldDisplay: Equatable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let displayBounds: CGRect
    let scale: CGFloat

    static func current() -> [ShieldDisplay]? {
        var displays: [ShieldDisplay] = []
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            displays.append(ShieldDisplay(id: id.uint32Value, frame: screen.frame,
                                          displayBounds: CGDisplayBounds(id.uint32Value), scale: screen.backingScaleFactor))
        }
        return displays
    }
}

final class LockShieldView: NSView {
    var image: NSImage { didSet { needsDisplay = true } }
    let displayBounds: CGRect
    var passwordFrame: CGRect? { didSet { needsLayout = true } }
    private let panel = NSView()
    private let title = NSTextField(labelWithString: "Chrome Consent 正在接管")
    private let status = NSTextField(labelWithString: "临时解锁处理中 · 操作键鼠将恢复锁屏")

    init(frame: CGRect, image: NSImage, displayBounds: CGRect) {
        self.image = image; self.displayBounds = displayBounds
        super.init(frame: frame)
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.82).cgColor
        panel.layer?.cornerRadius = 18
        panel.layer?.borderWidth = 0.5
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        title.font = .systemFont(ofSize: 16, weight: .semibold); title.textColor = .white
        status.font = .systemFont(ofSize: 12); status.textColor = NSColor.white.withAlphaComponent(0.8)
        for label in [title, status] { label.alignment = .center; panel.addSubview(label) }
        addSubview(panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        bounds.fill()
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1)
    }

    override func layout() {
        super.layout()
        panel.frame = shieldBannerFrame(in: bounds, display: displayBounds, password: passwordFrame)
        title.frame = CGRect(x: 12, y: 39, width: panel.bounds.width - 24, height: 22)
        status.frame = CGRect(x: 12, y: 15, width: panel.bounds.width - 24, height: 18)
    }

    func showRelocking() { status.stringValue = "正在恢复系统锁屏，请稍候" }
}

final class LockShield {
    private(set) var windows: [NSWindow] = []
    private var displayIDs: [CGDirectDisplayID] = []
    private var captureGeneration = UUID()
    private var geometry: [ShieldDisplay] = []

    var isReady: Bool {
        !windows.isEmpty && geometry == ShieldDisplay.current() && windows.count == geometry.count &&
            zip(windows, geometry).allSatisfy { $0.isVisible && $0.frame == $1.frame }
    }

    static func wallpaper(for screen: NSScreen) -> NSImage? {
        let urls = [NSWorkspace.shared.desktopImageURL(for: screen),
                    URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")].compactMap { $0 }
        for url in urls {
            if let image = NSImage(contentsOf: url), image.isValid, image.size.width > 0, image.size.height > 0 { return image }
        }
        return nil
    }

    func show() -> Bool {
        close()
        guard let geometry = ShieldDisplay.current() else { return false }
        let screens = NSScreen.screens
        for screen in screens {
            guard let image = Self.wallpaper(for: screen),
                  let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                close(); return false
            }
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
            window.isOpaque = true; window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.sharingType = .none
            window.contentView = LockShieldView(frame: CGRect(origin: .zero, size: screen.frame.size), image: image,
                                               displayBounds: CGDisplayBounds(id.uint32Value))
            window.orderFrontRegardless(); window.displayIfNeeded()
            windows.append(window); displayIDs.append(id.uint32Value)
        }
        self.geometry = geometry
        return isReady
    }

    func prepareNativeImage(password: CGRect?, completion: @escaping () -> Void) {
        let generation = UUID(); captureGeneration = generation
        for window in windows { (window.contentView as? LockShieldView)?.passwordFrame = password }
        let pid = cc_login_pid()
        var done = false
        var captured = 0
        let finish: () -> Void = { [weak self] in
            guard let self, !done, self.captureGeneration == generation else { return }
            done = true
            for window in self.windows { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
            record("shield_ready", ["nativeImages": captured, "wallpaperImages": self.windows.count - captured])
            completion()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: finish)
        Task { @MainActor [weak self] in
            guard let self, pid > 1, cc_lock_state() == 1 else { finish(); return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                for (index, id) in self.displayIDs.enumerated() {
                    guard !done, self.captureGeneration == generation, self.isReady, cc_lock_state() == 1 else { break }
                    let bounds = CGDisplayBounds(id)
                    let matches = content.windows.filter { $0.owningApplication?.processID == pid && $0.frame == bounds }
                    guard matches.count == 1 else { continue }
                    let config = SCStreamConfiguration()
                    config.width = CGDisplayPixelsWide(id); config.height = CGDisplayPixelsHigh(id)
                    config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                    let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: matches[0]), configuration: config)
                    guard !done, self.captureGeneration == generation, self.isReady, cc_lock_state() == 1,
                          Self.usable(image), let view = self.windows[index].contentView as? LockShieldView else { continue }
                    view.image = NSImage(cgImage: image, size: bounds.size)
                    captured += 1
                }
            } catch { record("shield_native_image_unavailable") }
            finish()
        }
    }

    static func usable(_ image: CGImage) -> Bool {
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 16, height: 16, bitsPerComponent: 8,
                                          bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            let data = bytes.bindMemory(to: UInt8.self)
            let offsets = stride(from: 0, to: data.count, by: 4)
            return offsets.allSatisfy { data[$0 + 3] == 255 } &&
                offsets.filter { max(data[$0], data[$0 + 1], data[$0 + 2]) > 16 }.count >= 32
        }
    }

    func showRelocking() {
        captureGeneration = UUID()
        for window in windows { (window.contentView as? LockShieldView)?.showRelocking() }
    }

    func close() {
        captureGeneration = UUID()
        for window in windows { window.orderOut(nil) }
        windows.removeAll(); displayIDs.removeAll(); geometry.removeAll()
    }
}

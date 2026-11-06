import AppKit
import ApplicationServices
import QuartzCore

enum PermissionKind: Int {
    case accessibility, screenCapture

    var title: String { self == .accessibility ? "辅助功能" : "屏幕录制" }
    var settingsURL: URL {
        let pane = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

struct PermissionSnapshot: Codable {
    let accessibility: Bool
    let screenCapture: Bool
    var complete: Bool { accessibility && screenCapture }
    var firstMissing: PermissionKind? { !accessibility ? .accessibility : !screenCapture ? .screenCapture : nil }
    func granted(_ kind: PermissionKind) -> Bool { kind == .accessibility ? accessibility : screenCapture }
    static func current() -> Self {
        Self(accessibility: AXIsProcessTrusted(), screenCapture: CGPreflightScreenCaptureAccess())
    }
}

final class PermissionProbe {
    private(set) var snapshot = PermissionSnapshot.current()
    private var busy = false
    func refresh(_ completion: @escaping (PermissionSnapshot) -> Void) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process(), output = Pipe()
            process.executableURL = Bundle.main.executableURL
            process.arguments = ["--permission-probe"]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            var result: PermissionSnapshot?
            do {
                try process.run(); try? output.fileHandleForWriting.close()
                let deadline = ProcessInfo.processInfo.systemUptime + 4
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning {
                    process.terminate(); Thread.sleep(forTimeInterval: 0.2)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                }
                else if process.terminationStatus == 0 {
                    result = try? JSONDecoder().decode(PermissionSnapshot.self, from: output.fileHandleForReading.readDataToEndOfFile())
                }
            } catch { result = nil }
            let observed = result ?? PermissionSnapshot(accessibility: false, screenCapture: false)
            DispatchQueue.main.async {
                self?.busy = false; self?.snapshot = observed; completion(observed)
            }
        }
    }
}

func permissionDragItem(for applicationURL: URL) -> NSDraggingItem? {
    guard applicationURL.isFileURL, applicationURL.pathExtension.lowercased() == "app",
          Bundle(url: applicationURL)?.bundleIdentifier == "local.chromeconsent.app" else { return nil }
    return NSDraggingItem(pasteboardWriter: applicationURL.standardizedFileURL as NSURL)
}

func applicationIcon(at url: URL) -> NSImage {
    NSImage(contentsOf: url.appendingPathComponent("Contents/Resources/AppIcon.icns")) ?? NSWorkspace.shared.icon(forFile: url.path)
}

enum GuideStyle {
    static let ink = NSColor(calibratedRed: 0.045, green: 0.14, blue: 0.17, alpha: 1)
    static let teal = NSColor(calibratedRed: 0.08, green: 0.43, blue: 0.36, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.38, green: 0.43, blue: 0.42, alpha: 1)
    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = ink
        return label
    }
}

final class GuideBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(calibratedWhite: 0.99, alpha: 1),
                           NSColor(calibratedRed: 0.91, green: 0.96, blue: 0.93, alpha: 1)])?.draw(in: bounds, angle: -45)
        GuideStyle.teal.withAlphaComponent(0.035).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.width - 200, y: bounds.height - 200, width: 360, height: 360)).fill()
    }
}

final class PermissionAppIcon: NSImageView, NSDraggingSource {
    let applicationURL: URL
    var onDragEnded: (() -> Void)?
    private var mouseOrigin: NSPoint?

    init(applicationURL: URL) {
        self.applicationURL = applicationURL
        super.init(frame: .zero)
        image = applicationIcon(at: applicationURL)
        imageScaling = .scaleProportionallyUpOrDown
        toolTip = "拖动 Chrome Consent 到系统权限列表\n\(applicationURL.path)"
        setAccessibilityLabel("Chrome Consent 应用，拖入系统权限列表")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { mouseOrigin = convert(event.locationInWindow, from: nil) }
    override func mouseUp(with event: NSEvent) { mouseOrigin = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) >= 4,
              let item = permissionDragItem(for: applicationURL), let image else { return }
        mouseOrigin = nil
        item.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // A completed file drop is not a TCC permission grant.
        onDragEnded?()
    }
}

private final class PermissionArrow: NSView {
    private var arrows: [CAShapeLayer] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for index in 0..<3 {
            let arrow = CAShapeLayer()
            let path = CGMutablePath()
            let x = CGFloat(index * 18 + 8)
            path.move(to: CGPoint(x: x, y: 9)); path.addLine(to: CGPoint(x: x + 8, y: 18))
            path.addLine(to: CGPoint(x: x, y: 27))
            arrow.path = path; arrow.lineWidth = 2.5; arrow.lineCap = .round; arrow.lineJoin = .round
            arrow.strokeColor = GuideStyle.teal.cgColor; arrow.fillColor = nil
            arrow.opacity = Float(0.35 + Double(index) * 0.25)
            layer?.addSublayer(arrow); arrows.append(arrow)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func animate(_ enabled: Bool) {
        for (index, arrow) in arrows.enumerated() {
            arrow.removeAllAnimations()
            guard enabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { continue }
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.18, 1, 0.18]; pulse.keyTimes = [0, 0.45, 1]
            pulse.duration = 1.7; pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.18
            arrow.add(pulse, forKey: "direction")
        }
    }
}

final class PermissionGuideController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let applicationURL: URL
    private let readPermissions: () -> PermissionSnapshot
    private let onReady: () -> Void
    private let onRestart: () -> Void
    private let needsRestart: () -> Bool
    private var selected: PermissionKind
    private let tabs = NSSegmentedControl(labels: ["辅助功能", "屏幕录制"], trackingMode: .selectOne, target: nil, action: nil)
    private let heading = GuideStyle.label("先开启两项权限", size: 26, weight: .semibold)
    private let instructions = GuideStyle.label("", size: 13)
    private let status = GuideStyle.label("", size: 13, weight: .medium)
    private let footnote = GuideStyle.label("", size: 11)
    private let openButton = NSButton(title: "打开系统设置", target: nil, action: nil)
    private let arrow = PermissionArrow(frame: .zero)
    private var timer: Timer?
    private var completionPending = false
    private var requestedScreenCapture = false
    private var observed: PermissionSnapshot

    init(applicationURL: URL = Bundle.main.bundleURL,
         readPermissions: @escaping () -> PermissionSnapshot = PermissionSnapshot.current,
         onReady: @escaping () -> Void = {}, onRestart: @escaping () -> Void = {}, needsRestart: @escaping () -> Bool = { false }) {
        self.applicationURL = applicationURL
        self.readPermissions = readPermissions
        self.onReady = onReady
        self.onRestart = onRestart
        self.needsRestart = needsRestart
        observed = readPermissions()
        selected = observed.firstMissing ?? .accessibility
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 562),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Chrome Consent · 权限设置"
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        buildContent()
        updateContent()
    }

    private func buildContent() {
        let root = GuideBackground(frame: NSRect(x: 0, y: 0, width: 470, height: 562))
        window.contentView = root
        let brand = GuideStyle.label("CHROME CONSENT  /  SETUP", size: 10, weight: .semibold)
        brand.textColor = GuideStyle.teal
        let intro = GuideStyle.label("用于识别 Chrome 授权窗口，并点击“允许”。", size: 13)
        intro.textColor = GuideStyle.muted
        tabs.target = self; tabs.action = #selector(selectPermission)
        tabs.segmentStyle = .rounded; tabs.controlSize = .large
        tabs.setWidth(185, forSegment: 0); tabs.setWidth(185, forSegment: 1)

        let stage = NSView()
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        stage.layer?.cornerRadius = 20
        stage.layer?.borderColor = GuideStyle.teal.withAlphaComponent(0.10).cgColor
        stage.layer?.borderWidth = 1
        let icon = PermissionAppIcon(applicationURL: applicationURL)
        icon.onDragEnded = { [weak self] in self?.refresh() }
        let sourceLabel = GuideStyle.label("按住图标拖动", size: 12, weight: .medium)
        let target = NSImageView(image: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "系统权限列表")!)
        target.contentTintColor = GuideStyle.teal
        target.imageScaling = .scaleProportionallyUpOrDown
        let destinationLabel = GuideStyle.label("系统权限列表", size: 12, weight: .medium)
        for view in [icon, sourceLabel, arrow, target, destinationLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false; stage.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stage.heightAnchor.constraint(equalToConstant: 158),
            icon.widthAnchor.constraint(equalToConstant: 104), icon.heightAnchor.constraint(equalToConstant: 104),
            icon.centerXAnchor.constraint(equalTo: stage.leadingAnchor, constant: 85), icon.topAnchor.constraint(equalTo: stage.topAnchor, constant: 10),
            sourceLabel.centerXAnchor.constraint(equalTo: icon.centerXAnchor), sourceLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 7),
            arrow.widthAnchor.constraint(equalToConstant: 70), arrow.heightAnchor.constraint(equalToConstant: 36),
            arrow.centerXAnchor.constraint(equalTo: stage.centerXAnchor), arrow.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            target.widthAnchor.constraint(equalToConstant: 50), target.heightAnchor.constraint(equalToConstant: 50),
            target.centerXAnchor.constraint(equalTo: stage.trailingAnchor, constant: -85), target.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            destinationLabel.centerXAnchor.constraint(equalTo: target.centerXAnchor), destinationLabel.centerYAnchor.constraint(equalTo: sourceLabel.centerYAnchor)
        ])
        openButton.target = self; openButton.action = #selector(openSettings)
        openButton.bezelStyle = .rounded; openButton.controlSize = .large
        openButton.bezelColor = GuideStyle.teal; openButton.keyEquivalent = "\r"
        let reveal = NSButton(title: "在 Finder 中显示应用", target: self, action: #selector(revealApplication))
        reveal.bezelStyle = .inline; reveal.font = .systemFont(ofSize: 11)
        footnote.textColor = GuideStyle.muted
        footnote.toolTip = applicationURL.path
        let restart = NSButton(title: "重新打开应用", target: self, action: #selector(restartApplication))
        restart.bezelStyle = .inline; restart.font = .systemFont(ofSize: 11)
        let shortcuts = NSStackView(views: [reveal, restart]); shortcuts.spacing = 16
        let stack = NSStackView(views: [brand, heading, intro, tabs, stage, instructions, openButton, status, footnote, shortcuts])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 13
        stack.setCustomSpacing(6, after: heading)
        stack.setCustomSpacing(20, after: intro)
        stack.setCustomSpacing(8, after: footnote)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 25),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)
        ])
        for view in [intro, stage, instructions, openButton, status, footnote] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        instructions.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    }

    func show(openSystemSettings: Bool = true) {
        observed = readPermissions()
        guard !observed.complete || needsRestart() else { onReady(); return }
        selected = observed.firstMissing ?? selected
        updateContent()
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameTopLeftPoint(NSPoint(x: frame.minX + 24, y: frame.midY + window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        arrow.animate(!observed.complete)
        timer?.invalidate()
        let polling = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(polling, forMode: .common); timer = polling
        if openSystemSettings && !observed.complete {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window.isVisible else { return }
                self.openSettings()
            }
        }
    }

    func refresh() {
        guard window.isVisible else { return }
        let previous = observed
        observed = readPermissions()
        if previous.complete != observed.complete { arrow.animate(!observed.complete) }
        if !previous.granted(selected), observed.granted(selected), let next = observed.firstMissing {
            selected = next
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window.isVisible else { return }
                self.openSettings()
            }
        }
        updateContent()
        guard observed.complete, !needsRestart(), !completionPending else { return }
        completionPending = true
        arrow.animate(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.completionPending = false
            guard self.window.isVisible, self.readPermissions().complete, !self.needsRestart() else { return }
            self.window.close(); self.onReady()
        }
    }

    private func updateContent() {
        tabs.selectedSegment = selected.rawValue
        for kind in [PermissionKind.accessibility, .screenCapture] {
            tabs.setLabel("\(observed.granted(kind) ? "✓ " : "")\(kind.title)", forSegment: kind.rawValue)
        }
        heading.stringValue = observed.complete ? (needsRestart() ? "重新打开后生效" : "权限已就绪") : "先开启两项权限"
        instructions.stringValue = "将左侧图标拖入系统设置的“\(selected.title)”列表，\n然后开启 Chrome Consent 的开关。"
        let count = (observed.accessibility ? 1 : 0) + (observed.screenCapture ? 1 : 0)
        status.stringValue = observed.complete ? (needsRestart() ? "✓  两项权限已开启，请重新打开应用" : "✓  两项权限已开启，即将返回应用") : "\(count) / 2 已开启 · 等待\(observed.firstMissing!.title)授权"
        status.textColor = observed.complete ? GuideStyle.teal : GuideStyle.muted
        footnote.stringValue = selected == .screenCapture
            ? "若系统提示重新打开应用，请按提示操作。\n授权对象：当前运行的 Chrome Consent（悬停查看路径）"
            : "授权对象：当前运行的 Chrome Consent\n拖入后如需验证身份，请在系统设置中完成。"
        openButton.title = observed.complete && needsRestart() ? "重新打开应用" : "打开\(selected.title)设置"
        openButton.isEnabled = !observed.complete || needsRestart()
    }

    @objc private func selectPermission() {
        guard let kind = PermissionKind(rawValue: tabs.selectedSegment) else { return }
        selected = kind; updateContent(); openSettings()
    }
    @objc private func openSettings() {
        if observed.complete && needsRestart() { onRestart(); return }
        if selected == .screenCapture, !observed.screenCapture, !requestedScreenCapture {
            requestedScreenCapture = true
            _ = CGRequestScreenCaptureAccess()
        }
        if !NSWorkspace.shared.open(selected.settingsURL) {
            status.stringValue = "请打开系统设置 → 隐私与安全性 → \(selected.title)"
        }
    }
    @objc private func revealApplication() { NSWorkspace.shared.activateFileViewerSelecting([applicationURL]) }
    @objc private func restartApplication() { onRestart() }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil; arrow.animate(false)
    }
    deinit { timer?.invalidate() }
}

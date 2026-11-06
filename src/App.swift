import AppKit
import ApplicationServices
import Foundation
import ServiceManagement

func configureMenuBarButton(_ button: NSButton) {
    button.title = ""
    button.image = NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: Product.title)
    button.image?.size = NSSize(width: 18, height: 18)
    button.image?.isTemplate = true
    button.imagePosition = .imageOnly
    button.toolTip = Product.title
    button.setAccessibilityLabel(Product.title)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow!
    private let store = RunStateStore()
    private let headline = NSTextField(labelWithString: "准备中")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let total = NSTextField(labelWithString: "0")
    private let recent = NSTextField(wrappingLabelWithString: "尚无处理记录")
    private let resultTime = NSTextField(labelWithString: "等待下一个授权窗口")
    private let primary = NSButton(title: "开始监测", target: nil, action: nil)
    private var timer: Timer?
    private var permissionGuide: PermissionGuideController?
    private let permissionProbe = PermissionProbe()
    private var permissions = PermissionSnapshot.current()
    private var screenRestartRequired = false
    private var installed = false
    private var maintenance = false
    private var quitting = false
    private var recovering = false
    private var deferredAction: (() -> Void)?
    private var notice: String?
    private var ignored = Set<Candidate>()
    private var click: ClickAttempt?
    private var guardian: Process?
    private var guardianInput: Pipe?
    private var guardianOutput: Pipe?
    private var guardianID = UUID()
    private var lastConditions: TimeInterval = -.infinity
    private var retryTimer: Timer?
    private var preview = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Bundle.main.bundlePath == Product.installedApp { store.recoverInterrupted() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button { configureMenuBarButton(button) }
        let menu = NSMenu(); menu.delegate = self
        menu.addItem(withTitle: "打开 Chrome Consent", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "开始监测", action: #selector(menuToggleMonitoring), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "登录后自动启动", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(withTitle: "查看日志", action: #selector(openLogs), keyEquivalent: "")
        menu.addItem(withTitle: "关于 Chrome Consent", action: #selector(about), keyEquivalent: "")
        menu.addItem(withTitle: "卸载 Chrome Consent…", action: #selector(uninstall), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        buildWindow(); refreshConditions()
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in self?.tick() }
        record("app_started", ["version": Product.version, "monitoring": store.state.monitoring])
        if installed && permissions.complete { refreshUI() }
        else { showWindow(); DispatchQueue.main.async { [weak self] in self?.beginSetup() } }
    }

    func buildWindow(preview: Bool = false) {
        self.preview = preview
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Chrome Consent"
        window.isReleasedWhenClosed = false; window.center(); window.appearance = NSAppearance(named: .aqua)
        let root = GuideBackground(frame: NSRect(x: 0, y: 0, width: 570, height: 420)); window.contentView = root
        let icon = NSImageView(image: applicationIcon(at: Bundle.main.bundleURL))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true; icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let brand = GuideStyle.label("Chrome Consent", size: 23, weight: .semibold)
        let subtitle = GuideStyle.label("Chrome 调试授权助手", size: 12); subtitle.textColor = GuideStyle.muted
        let branding = NSStackView(views: [brand, subtitle]); branding.orientation = .vertical; branding.alignment = .leading; branding.spacing = 3
        let top = NSStackView(views: [icon, branding]); top.spacing = 12
        headline.font = .systemFont(ofSize: 28, weight: .semibold); headline.textColor = GuideStyle.teal
        detail.font = .systemFont(ofSize: 13); detail.textColor = GuideStyle.muted
        total.font = .monospacedDigitSystemFont(ofSize: 40, weight: .light); total.textColor = GuideStyle.ink
        let countTitle = GuideStyle.label("累计成功", size: 11); countTitle.textColor = GuideStyle.muted
        let countStack = NSStackView(views: [countTitle, total]); countStack.orientation = .vertical; countStack.alignment = .leading; countStack.spacing = 6
        let resultTitle = GuideStyle.label("最近一次处理", size: 11); resultTitle.textColor = GuideStyle.muted
        recent.font = .systemFont(ofSize: 15, weight: .medium); recent.textColor = GuideStyle.ink
        recent.maximumNumberOfLines = 3; recent.lineBreakMode = .byTruncatingTail
        resultTime.font = .systemFont(ofSize: 11); resultTime.textColor = GuideStyle.muted
        let resultStack = NSStackView(views: [resultTitle, recent, resultTime]); resultStack.orientation = .vertical; resultStack.alignment = .leading; resultStack.spacing = 8
        let divider = NSBox(); divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true; divider.heightAnchor.constraint(equalToConstant: 72).isActive = true
        let metrics = NSStackView(views: [countStack, divider, resultStack]); metrics.spacing = 25; metrics.alignment = .top
        countStack.widthAnchor.constraint(equalToConstant: 112).isActive = true; resultStack.widthAnchor.constraint(equalToConstant: 315).isActive = true
        recent.widthAnchor.constraint(equalTo: resultStack.widthAnchor).isActive = true
        primary.target = self; primary.action = #selector(toggleMonitoring); primary.bezelStyle = .rounded
        primary.controlSize = .large; primary.bezelColor = GuideStyle.teal; primary.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let footer = GuideStyle.label("在菜单栏中持续运行", size: 11); footer.textColor = GuideStyle.muted
        let bottom = NSStackView(views: [primary, footer]); bottom.spacing = 16
        let stack = NSStackView(views: [top, headline, detail, metrics, bottom])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.setCustomSpacing(24, after: top); stack.setCustomSpacing(8, after: headline); stack.setCustomSpacing(25, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 26), stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refreshUI()
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); refreshUI() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard window != nil else { return }
        refreshConditions(); permissionGuide?.refresh(); refreshUI()
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.item(at: 1)?.title = store.state.monitoring ? "暂停监测" : "开始监测"
        let status = SMAppService.mainApp.status
        menu.item(at: 3)?.state = status == .enabled ? .on : status == .requiresApproval ? .mixed : .off
        menu.item(at: 3)?.isEnabled = installed && !maintenance
    }
    private func refreshConditions() {
        installed = cc_install_ready() == 1
        updatePermissions(permissionProbe.snapshot)
        permissionProbe.refresh { [weak self] snapshot in
            guard let self else { return }
            self.updatePermissions(snapshot)
            self.permissionGuide?.refresh(); self.refreshUI()
        }
        lastConditions = ProcessInfo.processInfo.systemUptime
    }
    private func updatePermissions(_ snapshot: PermissionSnapshot) {
        screenRestartRequired = snapshot.screenCapture && !CGPreflightScreenCaptureAccess()
        permissions = PermissionSnapshot(accessibility: snapshot.accessibility, screenCapture: snapshot.screenCapture && !screenRestartRequired)
    }
    private func refreshUI() {
        let running = preview || (store.state.monitoring && installed && permissions.complete)
        let busy = guardian != nil || click != nil || recovering
        headline.stringValue = maintenance ? "准备应用" : quitting ? "正在退出" : busy ? "正在处理授权" : !preview && (!installed || !permissions.complete) ? "需要设置" : running ? "监测中" : "已暂停"
        detail.stringValue = notice ?? (recovering ? "正在等待上一次锁屏恢复流程结束。" : busy ? "正在完成当前授权流程。" : !preview && !installed ? "完成安装后，即可开始自动处理授权。" : !preview && !permissions.complete ? "完成系统权限设置后即可继续。" : running ? "自动处理 Chrome 调试授权窗口。" : "点击开始后，继续自动处理 Chrome 授权。")
        total.stringValue = String(store.state.successCount)
        if let latest = store.state.recent.first {
            recent.stringValue = latest.message; recent.toolTip = latest.message; recent.textColor = latest.success ? GuideStyle.ink : .systemOrange
            resultTime.stringValue = DateFormatter.localizedString(from: latest.time, dateStyle: .short, timeStyle: .medium)
        }
        primary.title = !preview && (!installed || !permissions.complete) ? "完成设置" : store.state.monitoring ? "暂停监测" : "开始监测"
        primary.isEnabled = !maintenance && !quitting
    }
    private func beginSetup() {
        guard !maintenance, !quitting, cc_lock_state() == 0 else { return }
        if !installed { adminOperation("install"); return }
        if permissions.complete { notice = nil; refreshUI(); return }
        if permissionGuide?.window.isVisible == true { permissionGuide?.window.makeKeyAndOrderFront(nil); return }
        permissionGuide = PermissionGuideController(readPermissions: { [weak self] in self?.permissionProbe.snapshot ?? .current() }, onReady: { [weak self] in
            self?.notice = nil; self?.refreshConditions(); self?.refreshUI()
        }, onRestart: { [weak self] in self?.restartInstalled() }, needsRestart: { [weak self] in self?.screenRestartRequired ?? false })
        permissionGuide?.show()
    }
    @objc private func toggleMonitoring() {
        if !installed || !permissions.complete { beginSetup(); return }
        menuToggleMonitoring()
    }
    @objc private func menuToggleMonitoring() {
        store.setMonitoring(!store.state.monitoring); notice = nil
        if !store.state.monitoring { cancelCurrent() }
        record(store.state.monitoring ? "monitor_started" : "monitor_paused"); refreshUI()
        if store.state.monitoring && (!installed || !permissions.complete) { beginSetup() }
    }
    private func cancelCurrent() {
        try? guardianInput?.fileHandleForWriting.close(); guardianInput = nil
        if click != nil { finishClick(success: false, message: "处理已停止") }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastConditions >= (permissionGuide?.window.isVisible == true ? 2 : 15) { refreshConditions() }
        if let process = guardian, !process.isRunning { finishGuardian(process) }
        recovering = installed && guardian == nil && ProtectionLocks.active
        if recovering { refreshUI(); return }
        if guardian == nil, click == nil, let action = deferredAction { deferredAction = nil; action(); return }
        if guardian != nil { if !permissions.complete { cancelCurrent() }; refreshUI(); return }
        if var attempt = click {
            let dialog = attempt.sent ? authorizationPresence(attempt.target) : .unavailable
            let progress = attempt.progress(now: now, present: candidateSnapshot(), permissions: permissions.complete,
                                            unlocked: cc_lock_state() == 0, chromeRunning: trustedChrome(attempt.target.pid), dialog: dialog)
            click = attempt
            switch progress {
            case .succeeded:
                record("dialog_dismissed", ["evidence": attempt.dismissal.evidence ?? "unknown"])
                finishClick(success: true, message: "已同意 Chrome 授权")
            case .timedOut:
                record("dialog_timeout_observation", authorizationDiagnostics(attempt.target, presence: dialog, clickSent: attempt.sent))
                finishClick(success: false, message: "授权窗口未能关闭")
            case .interrupted: finishClick(success: false, message: "会话或权限发生变化")
            case .waiting:
                if !attempt.sent, attempt.tries < 3, now - attempt.lastTry >= 1 {
                    attempt.tries += 1; attempt.lastTry = now; attempt.sent = clickAuthorization(attempt.target); click = attempt
                }
            }
            refreshUI(); return
        }
        guard !maintenance, !quitting, store.state.monitoring, installed, permissions.complete,
              let found = candidateSnapshot() else { refreshUI(); return }
        ignored.formIntersection(Set(found))
        guard found.count == 1, let target = found.first, !ignored.contains(target) else { refreshUI(); return }
        let state = cc_lock_state(); guard state == 0 || state == 1 else { return }
        ignored.insert(target); record("dialog_detected", ["windowID": target.windowID, "pid": target.pid])
        if state == 0 {
            let attempt = ClickAttempt(target: target, started: now)
            store.begin(id: attempt.id, locked: false); click = attempt
        } else { launchGuardian(target) }
        refreshUI()
    }
    private func finishClick(success: Bool, message: String) {
        guard let attempt = click else { return }
        click = nil; saveResult(OperationResult(id: attempt.id, success: success, locked: false, message: message))
    }
    private func saveResult(_ result: OperationResult) {
        store.append(result)
        record("operation_finished", ["id": result.id.uuidString, "success": result.success, "locked": result.locked, "message": result.message])
        notice = result.success ? nil : "最近一次处理未完成，可从菜单查看日志。"
    }
    private func launchGuardian(_ target: Candidate) {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--guardian", String(getpid()), String(target.windowID), String(target.pid)]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guardianID = UUID(); store.begin(id: guardianID, locked: true)
        do {
            try process.run(); try? output.fileHandleForWriting.close()
            guardian = process; guardianInput = input; guardianOutput = output
        } catch { saveResult(OperationResult(id: guardianID, success: false, locked: true, message: "无法启动锁屏处理：\(error.localizedDescription)")) }
    }
    private func finishGuardian(_ process: Process) {
        let data = guardianOutput?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let success = process.terminationStatus == 0 && payload?["success"] as? Bool == true && cc_lock_state() == 1
        if cc_lock_state() == 0 { cc_request_lock() }
        let reason = payload?["reason"] as? String ?? "guardian_exit_\(process.terminationStatus)"
        record("guardian_exited", ["status": process.terminationStatus, "reason": reason])
        saveResult(OperationResult(id: guardianID, success: success, locked: true,
            message: success ? "已同意授权，并恢复锁屏" : guardianResultMessage(reason)))
        guardian = nil; guardianInput = nil; guardianOutput = nil
    }
    @objc private func toggleLogin() {
        guard installed else { return }
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register(); if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() } }
        } catch { message("无法更改登录启动设置", error.localizedDescription) }
    }
    @objc private func about() { message("Chrome Consent \(Product.version)", "自动处理 Chrome 调试授权。\n支持解锁及锁屏场景。") }
    @objc private func openLogs() {
        try? FileManager.default.createDirectory(at: Product.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        NSWorkspace.shared.open(Product.logURL.deletingLastPathComponent())
    }
    @objc private func uninstall() { stopThen { [weak self] in self?.adminOperation("uninstall") } }
    private func stopThen(_ action: @escaping () -> Void) {
        maintenance = true; cancelCurrent()
        if guardian != nil { deferredAction = action; notice = "完成当前锁屏恢复后继续。" } else { action() }
        refreshUI()
    }
    private func adminOperation(_ operation: String) {
        guard cc_lock_state() == 0, guardian == nil else { maintenance = false; notice = "请解锁后完成安装操作。"; refreshUI(); return }
        let alert = NSAlert(); alert.messageText = operation == "install" ? "准备 Chrome Consent" : "卸载 Chrome Consent？"
        alert.informativeText = operation == "install" ? "将安装或更新应用及锁屏处理组件。下一步需要系统管理员授权。" : "将移除应用和配套组件。"
        let clear = NSButton(checkboxWithTitle: "同时清除设置、统计和日志", target: nil, action: nil)
        if operation == "uninstall" { alert.accessoryView = clear }
        alert.addButton(withTitle: operation == "install" ? "安装并继续" : "卸载"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { maintenance = false; refreshUI(); return }
        maintenance = true; notice = operation == "install" ? "正在准备安装，请完成系统授权。" : "正在卸载。"; refreshUI()
        stopOtherCopies { [weak self] in self?.executeInstaller(operation, clearData: clear.state == .on) }
    }
    private func stopOtherCopies(_ action: @escaping () -> Void) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.chromeconsent.app").filter {
            $0.processIdentifier != getpid() && $0.bundleURL?.path == Product.installedApp
        }
        guard !others.isEmpty else { action(); return }
        for app in others { _ = app.terminate() }
        let deadline = Date().addingTimeInterval(30)
        retryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            if others.allSatisfy({ $0.isTerminated }) { timer.invalidate(); self?.retryTimer = nil; action() }
            else if Date() > deadline {
                timer.invalidate(); self?.retryTimer = nil; self?.maintenance = false
                self?.message("请先退出正在运行的版本", "等待其完成当前授权流程后，再继续安装。"); self?.refreshUI()
            }
        }
    }
    private func executeInstaller(_ operation: String, clearData: Bool) {
        let registered = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        if operation == "uninstall", registered {
            do { try SMAppService.mainApp.unregister() }
            catch { maintenance = false; message("无法移除登录启动项", error.localizedDescription); refreshUI(); return }
        }
        guard let resources = Bundle.main.resourceURL else { maintenance = false; return }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "/usr/bin/python3 -I \(quote(resources.appendingPathComponent("installer.py").path)) \(operation) --source \(quote(Bundle.main.bundlePath)) --uid \(getuid()) --caller-pid \(getpid())"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        let result = script?.executeAndReturnError(&error)
        if error != nil || result == nil {
            maintenance = false
            if operation == "uninstall", registered { try? SMAppService.mainApp.register() }
            let text = error?[NSAppleScript.errorMessage] as? String ?? "系统安装器未返回结果。"
            record("installer_failed", ["message": text]); message("操作未完成", text); refreshUI(); return
        }
        if operation == "install" { restartInstalled(); return }
        if clearData {
            UserDefaults.standard.removePersistentDomain(forName: "local.chromeconsent.app")
            try? FileManager.default.removeItem(at: Product.logURL.deletingLastPathComponent())
        }
        quitting = true; NSApp.terminate(nil)
    }
    private func restartInstalled() {
        guard guardian == nil else { stopThen { [weak self] in self?.restartInstalled() }; return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Product.installedApp, "--args", "--wait-for-exit", String(getpid())]
        do { try process.run(); quitting = true; NSApp.terminate(nil) }
        catch { maintenance = false; message("请重新打开 Chrome Consent", error.localizedDescription); refreshUI() }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if guardian != nil {
            quitting = true; cancelCurrent(); deferredAction = { NSApp.reply(toApplicationShouldTerminate: true) }
            refreshUI(); return .terminateLater
        }
        cancelCurrent(); return .terminateNow
    }
    private func message(_ title: String, _ body: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = body; alert.runModal()
    }
}

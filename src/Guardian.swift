import AppKit
import ApplicationServices
import Foundation

final class Guardian: NSObject {
    enum Phase { case preparing, preparingLogin, preparingShield, waitingUnlock, clicking, relocking }
    let parentPID: Int32
    let target: Candidate
    let lease = SingleUseLease()
    let login = LoginPreparation()
    var authorizationApproved = false
    var pluginRequestReceived = false
    var inputInterrupted = false
    var phase = Phase.preparing
    let shield = LockShield()
    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var timer: Timer?
    var listener: Int32 = -1
    var watchdog: Process?
    var watchdogPipe: Pipe?
    var watchdogOutput: Pipe?
    var began = ProcessInfo.processInfo.systemUptime
    var phaseBegan = ProcessInfo.processInfo.systemUptime
    var lockSamples = 0
    var clickSent = false
    var lastClick: TimeInterval = 0
    var finishing = false
    var lastRelock: TimeInterval = 0
    var completionReason = "not_completed"
    var dialogDismissed = false
    var dismissal = DismissalTracker()
    var ownership: ProcessLease?

    init(parent: Int32, target: Candidate) { self.parentPID = parent; self.target = target }

    func start() {
        guard ownParent(parentPID), cc_install_ready() == 1, cc_lock_state() == 1, cc_lock_available() == 1,
              cc_console_uid() == Int32(getuid()), AXIsProcessTrusted(), candidates() == [target] else {
            record("guardian_preflight_denied"); exit(3)
        }
        guard !ProtectionLocks.active, let lease = ProcessLease.acquire(ProtectionLocks.guardian) else {
            record("guardian_recovery_in_progress"); exit(3)
        }
        ownership = lease
        guard startInputMonitor() else { record("guardian_input_monitor_unavailable"); exit(4) }
        listener = cc_socket_listen()
        guard listener >= 0 else { record("guardian_socket_unavailable"); exit(5) }
        showShield()
        startServer()
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
                DispatchQueue.main.async { self?.relock("parent_channel_closed") }
            }
        }
        do {
            let p = Process(), input = Pipe(), output = Pipe()
            p.executableURL = Bundle.main.executableURL
            p.arguments = ["--watchdog", String(getpid())]
            p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
            watchdog = p; watchdogPipe = input; watchdogOutput = output
            output.fileHandleForReading.readabilityHandler = { [weak self] h in
                let data = h.availableData
                DispatchQueue.main.async {
                    guard let self else { return }
                    if String(data: data, encoding: .utf8)?.contains("READY") == true {
                        self.prepareUnlock()
                    } else if data.isEmpty {
                        h.readabilityHandler = nil
                        self.relock("watchdog_channel_closed")
                    }
                }
            }
            try p.run()
            try input.fileHandleForWriting.write(contentsOf: Data("ARM\n".utf8))
        } catch {
            relock("watchdog_start_failed")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        record("guardian_started", ["windowID": target.windowID])
    }

    func showShield() {
        guard shield.show() else {
            record("shield_wallpaper_unavailable")
            if listener >= 0 { close(listener) }
            cc_socket_cleanup()
            exit(7)
        }
    }

    func startInputMonitor() -> Bool {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                                   .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                   .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, kind, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<Guardian>.fromOpaque(pointer).takeUnretainedValue()
                if kind == .tapDisabledByTimeout || kind == .tapDisabledByUserInput {
                    me.inputInterrupted = true
                    me.lease.revoke()
                    DispatchQueue.main.async { me.relock("input_monitor_disabled") }
                    return Unmanaged.passUnretained(event)
                }
                let source = Int32(event.getIntegerValueField(.eventSourceUnixProcessID))
                if source == getpid() || source == me.watchdog?.processIdentifier { return Unmanaged.passUnretained(event) }
                me.inputInterrupted = true
                me.lease.revoke()
                DispatchQueue.main.async { me.relock("external_input") }
                return nil
            }, userInfo: pointer) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func startServer() {
        let fd = listener
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let self {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                defer { close(client) }
                var buffer = [CChar](repeating: 0, count: 128)
                guard cc_peer_is_security_agent(client) == 1,
                      cc_read_line(client, &buffer, Int32(buffer.count)) > 0 else { continue }
                let request = String(cString: buffer)
                guard let nonce = clientRequest(request, owner: Int(getuid())) else { continue }
                let approved = DispatchQueue.main.sync {
                    self.pluginRequestReceived = true
                    let eligible = self.phase == .waitingUnlock && !self.finishing && !self.inputInterrupted &&
                        self.shield.isReady &&
                        cc_lock_state() == 1 && cc_console_uid() == Int32(getuid()) &&
                        kill(self.parentPID, 0) == 0 && self.watchdog?.isRunning == true &&
                        self.tap.map { CGEvent.tapIsEnabled(tap: $0) } == true && candidates() == [self.target]
                    let allowed = self.lease.consume(eligible: eligible)
                    self.authorizationApproved = self.authorizationApproved || allowed
                    return allowed
                }
                let response = approved ? "ALLOW \(nonce)\n" : "DENY\n"
                let sent = response.withCString { cc_write_line(client, $0) } == 1
                record("plugin_request", ["approved": approved, "responseSent": sent])
            }
        }
    }

    func prepareUnlock() {
        guard phase == .preparing, !inputInterrupted, cc_lock_state() == 1, candidates() == [target],
              shield.isReady, let tap, CGEvent.tapIsEnabled(tap: tap) else { relock("prepare_changed"); return }
        phase = .preparingLogin; phaseBegan = ProcessInfo.processInfo.systemUptime
        guard login.begin() else { relock("login_display_unavailable"); return }
        record("login_preparation_started")
    }

    func submitLogin() {
        guard phase == .preparingShield, shield.isReady, !inputInterrupted, cc_lock_state() == 1, cc_console_uid() == Int32(getuid()),
              candidates() == [target], let tap, CGEvent.tapIsEnabled(tap: tap),
              watchdog?.isRunning == true, kill(parentPID, 0) == 0 else { relock("prepare_changed"); return }
        // Arm only after the native login field is ready, so UI setup cannot consume the lease lifetime.
        lease.arm()
        phase = .waitingUnlock; phaseBegan = ProcessInfo.processInfo.systemUptime
        guard login.submit() else { relock("login_submit_unavailable"); return }
        record("login_submit_dispatched", ["method": "return_key"])
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if kill(parentPID, 0) != 0 || watchdog?.isRunning != true { relock("peer_exited") }
        if inputInterrupted && phase != .relocking { relock("external_input") }
        if !shield.isReady && phase != .relocking { relock("display_configuration_changed") }
        if now - began > 15 && phase != .relocking { relock("operation_timeout") }
        switch phase {
        case .preparing:
            if now - began > 3 { relock("watchdog_not_ready") }
        case .preparingLogin:
            guard cc_lock_state() == 1, cc_console_uid() == Int32(getuid()),
                  let tap, CGEvent.tapIsEnabled(tap: tap) else { relock("prepare_changed"); return }
            if now - phaseBegan > 4 { relock("login_ui_not_ready"); return }
            switch login.advance(now: now) {
            case .ready:
                phase = .preparingShield; phaseBegan = ProcessInfo.processInfo.systemUptime
                shield.prepareNativeImage(password: login.passwordFrame) { [weak self] in
                    guard let self, self.phase == .preparingShield else { return }
                    self.submitLogin()
                }
            case .waiting: break
            case .failed(let reason): relock(reason)
            }
        case .preparingShield:
            if now - phaseBegan > 2 { relock("shield_not_ready") }
        case .waitingUnlock:
            if cc_lock_state() == 0 {
                guard authorizationApproved else { relock("unexpected_unlock"); return }
                lease.revoke(); phase = .clicking; phaseBegan = now
                record("native_session_unlocked")
            } else if now - phaseBegan > 5 {
                relock(!pluginRequestReceived ? "plugin_not_contacted" : !authorizationApproved ? "plugin_denied" : "unlock_not_confirmed")
            }
        case .clicking:
            if cc_lock_state() != 0 { relock("session_changed"); return }
            guard let present = candidateSnapshot(), CGPreflightScreenCaptureAccess() else { relock("window_query_unavailable"); return }
            guard trustedChrome(target.pid) else { relock("dialog_changed"); return }
            let dialog = clickSent ? authorizationPresence(target) : .unavailable
            if dismissal.observe(sent: clickSent, targetPresent: present.contains(target), dialog: dialog, now: now) {
                dialogDismissed = true
                record("dialog_dismissed", ["evidence": dismissal.evidence ?? "unknown"]); relock("dialog_dismissed"); return
            }
            if present != [target] { relock("dialog_changed"); return }
            if now - phaseBegan > 5 {
                record("dialog_timeout_observation", authorizationDiagnostics(target, presence: dialog, clickSent: clickSent))
                relock("dialog_timeout"); return
            }
            if !clickSent && now - lastClick > 1 {
                lastClick = now
                clickSent = clickAuthorization(target) || clickSent
            }
        case .relocking:
            if cc_lock_state() == 1 { lockSamples += 1 } else { lockSamples = 0 }
            if lockSamples >= 5 && now - phaseBegan >= 3 && now - began >= 10 { complete(); return }
            if cc_lock_state() != 1 && now - lastRelock > 0.8 { lastRelock = now; cc_request_lock() }
        }
    }

    func relock(_ reason: String) {
        guard !finishing, phase != .relocking else { return }
        login.finish()
        shield.showRelocking()
        lease.revoke(); phase = .relocking; lockSamples = 0
        completionReason = reason
        phaseBegan = ProcessInfo.processInfo.systemUptime
        record("relock_requested", ["reason": reason])
        if cc_lock_state() != 1 { cc_request_lock() }
    }

    func complete() {
        guard !finishing, cc_lock_state() == 1 else { return }
        login.finish()
        finishing = true; lease.revoke()
        record("native_lock_confirmed")
        try? watchdogPipe?.fileHandleForWriting.write(contentsOf: Data("DISARM\n".utf8))
        try? watchdogPipe?.fileHandleForWriting.close()
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener) }
        cc_socket_cleanup()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        shield.close()
        let success = dialogDismissed && completionReason == "dialog_dismissed"
        if let data = try? JSONSerialization.data(withJSONObject: ["success": success, "reason": completionReason]) {
            FileHandle.standardOutput.write(data)
        }
        exit(success ? 0 : 6)
    }
}

final class Watchdog {
    let parent: Int32
    var armed = false
    var triggered = false
    var lockSamples = 0
    var lastLock: TimeInterval = 0
    var timer: Timer?
    var ownership: ProcessLease?
    init(parent: Int32) { self.parent = parent }
    func start() {
        guard ownParent(parent), cc_install_ready() == 1, cc_lock_available() == 1 else { exit(3) }
        guard let lease = ProcessLease.acquire(ProtectionLocks.watchdog) else { exit(3) }
        ownership = lease
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self else { return }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if self.armed { self.triggered = true } else { exit(0) }
                } else if String(data: data, encoding: .utf8)?.contains("DISARM\n") == true {
                    if cc_lock_state() == 1 { exit(0) } else { self.triggered = true }
                } else if String(data: data, encoding: .utf8) == "ARM\n" && !self.armed && cc_lock_state() == 1 {
                    self.armed = true
                    FileHandle.standardOutput.write(Data("READY\n".utf8))
                }
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if kill(self.parent, 0) != 0 || now - start > 20 { self.triggered = self.armed }
            if !self.armed && now - start > 4 { exit(0) }
            guard self.triggered else { return }
            if cc_lock_state() == 1 { self.lockSamples += 1 } else { self.lockSamples = 0 }
            if self.lockSamples >= 5 && now - start >= 15 { record("watchdog_lock_confirmed"); exit(0) }
            if cc_lock_state() != 1 && now - self.lastLock > 0.8 { self.lastLock = now; cc_request_lock() }
        }
    }
}

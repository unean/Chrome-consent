import AppKit
import ApplicationServices
import IOKit.pwr_mgt

struct LoginElement {
    let element: AXUIElement
    let role: String
    let identifier: String
    let frame: CGRect?
    let enabled: Bool
}

struct LoginScreenSnapshot {
    let pid: pid_t
    let elements: [LoginElement]

    var password: AXUIElement? {
        let matches = elements.filter {
            $0.identifier == "UserPasswordTextField" && $0.role == kAXTextFieldRole &&
                $0.enabled && $0.frame != nil && axValue($0.element, kAXEnabledAttribute) as? Bool == true
        }
        return matches.count == 1 ? matches[0].element : nil
    }

    var wakeTarget: LoginElement? {
        let users = elements.filter { $0.identifier == "FocusedUser" }
        guard users.count == 1, let user = users[0].frame else { return nil }
        let labels = elements.filter {
            guard $0.role == kAXStaticTextRole, $0.identifier.isEmpty, $0.enabled, let frame = $0.frame else { return false }
            return loginWakeDistance(user: user, label: frame) != nil &&
                !axText($0.element, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted {
            let a = loginWakeDistance(user: user, label: $0.frame!)!
            let b = loginWakeDistance(user: user, label: $1.frame!)!
            return a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }
        guard let first = labels.first else { return nil }
        if labels.count > 1, labels[1].frame == first.frame { return nil }
        return first
    }
}

func loginWakeDistance(user: CGRect, label: CGRect) -> (CGFloat, CGFloat)? {
    let vertical = label.minY - user.maxY, horizontal = abs(label.midX - user.midX)
    guard !user.isEmpty, !label.isEmpty, vertical >= 0, vertical <= 120, horizontal <= 240 else { return nil }
    return (vertical, horizontal)
}

private func loginFrame(_ element: AXUIElement) -> CGRect? {
    guard let position = axValue(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = axValue(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
          point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
          dimensions.width > 0, dimensions.height > 0 else { return nil }
    return CGRect(origin: point, size: dimensions)
}

func loginScreenSnapshot() -> LoginScreenSnapshot? {
    let pid = cc_login_pid()
    guard pid > 1 else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.08)
    guard let windows = axValue(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
    var queue = windows.map { ($0, 0) }, seen: [AXUIElement] = [], result: [LoginElement] = []
    let deadline = ProcessInfo.processInfo.systemUptime + 0.7
    while let (element, depth) = queue.popLast() {
        guard result.count < 256, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        if seen.contains(where: { CFEqual($0, element) }) { continue }
        seen.append(element)
        let role = axText(element, kAXRoleAttribute)
        guard !role.isEmpty else { return nil }
        result.append(LoginElement(element: element, role: role, identifier: axText(element, kAXIdentifierAttribute),
                                   frame: loginFrame(element), enabled: axValue(element, kAXEnabledAttribute) as? Bool ?? true))
        let children = axChildren(element)
        guard depth < 8 || children.isEmpty else { return nil }
        queue += children.map { ($0, depth + 1) }
    }
    return LoginScreenSnapshot(pid: pid, elements: result)
}

enum LoginPreparationResult { case waiting, ready, failed(String) }

final class LoginPreparation {
    private var displayAssertion: IOPMAssertionID?
    private var wakeSent = false
    private var prepared: AXUIElement?
    private var preparedAt: TimeInterval = 0
    private var loginPID: pid_t = -1
    private(set) var submitted = false
    private(set) var passwordFrame: CGRect?

    func begin() -> Bool {
        guard displayAssertion == nil, cc_lock_state() == 1 else { return false }
        var assertion: IOPMAssertionID = 0
        guard IOPMAssertionDeclareUserActivity("Chrome Consent login preparation" as CFString,
                                              kIOPMUserActiveLocal, &assertion) == kIOReturnSuccess else { return false }
        displayAssertion = assertion
        record("login_display_wake_requested")
        return true
    }

    func finish() {
        if let displayAssertion { IOPMAssertionRelease(displayAssertion) }
        displayAssertion = nil
    }

    deinit { finish() }

    func advance(now: TimeInterval) -> LoginPreparationResult {
        guard displayAssertion != nil, !submitted else { return .failed("login_preparation_inactive") }
        guard let snapshot = loginScreenSnapshot() else { return .waiting }
        if loginPID > 1 && snapshot.pid != loginPID { return .failed("login_process_changed") }
        loginPID = snapshot.pid
        guard let field = snapshot.password else {
            if prepared != nil { return .failed("login_field_changed") }
            if !wakeSent, let target = snapshot.wakeTarget, let frame = target.frame {
                guard cc_lock_state() == 1, cc_console_uid() == Int32(getuid()), cc_login_pid() == loginPID else {
                    return .failed("prepare_changed")
                }
                guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                         mouseCursorPosition: CGPoint(x: frame.midX, y: frame.midY), mouseButton: .left),
                      let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                       mouseCursorPosition: CGPoint(x: frame.midX, y: frame.midY), mouseButton: .left) else {
                    return .failed("login_wake_unavailable")
                }
                for event in [down, up] {
                    event.flags = []
                    event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
                    event.setIntegerValueField(.mouseEventClickState, value: 1)
                    event.post(tap: .cghidEventTap)
                }
                wakeSent = true
                record("login_wake_dispatched", ["method": "login_label_click"])
            }
            return .waiting
        }
        passwordFrame = snapshot.elements.first { CFEqual($0.element, field) }?.frame
        // Never submit credentials already present in the native password field.
        guard let value = axValue(field, kAXValueAttribute) as? String, value.isEmpty else {
            return .failed("login_field_not_empty")
        }
        if let prepared {
            guard CFEqual(prepared, field), axValue(field, kAXFocusedAttribute) as? Bool == true else {
                return .failed("login_field_changed")
            }
            return now - preparedAt >= 0.35 ? .ready : .waiting
        }
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString) == .success else {
            return .failed("login_field_unavailable")
        }
        if axValue(field, kAXFocusedAttribute) as? Bool != true {
            guard AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
                return .failed("login_focus_unavailable")
            }
        }
        prepared = field; preparedAt = ProcessInfo.processInfo.systemUptime
        record("login_field_prepared")
        return .waiting
    }

    func submit() -> Bool {
        guard displayAssertion != nil, !submitted, let prepared, cc_login_pid() == loginPID,
              axValue(prepared, kAXFocusedAttribute) as? Bool == true,
              let value = axValue(prepared, kAXValueAttribute) as? String, value.isEmpty else { return false }
        submitted = true
        return cc_submit_login(loginPID) == 1
    }
}

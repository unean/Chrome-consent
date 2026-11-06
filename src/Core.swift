import AppKit
import ApplicationServices
import Foundation
import Security

enum Product {
    static let version = "1.0.1"
    static let support = "/Library/Application Support/ChromeConsent"
    static let installedApp = "/Applications/Chrome Consent.app"
    static let title = "Chrome Consent"
    static let titles: Set<String> = ["要允许远程调试吗？", "Allow remote debugging?"]
    static let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/ChromeConsent/events.jsonl")
}

func record(_ event: String, _ fields: [String: Any] = [:]) {
    var data = fields
    data["event"] = event
    data["time"] = ISO8601DateFormatter().string(from: Date())
    data["lockState"] = Int(cc_lock_state())
    guard let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else { return }
    try? FileManager.default.createDirectory(at: Product.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(Product.logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
    if fd >= 0 {
        let line = encoded + Data([10])
        line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }
}

struct Candidate: Equatable, Hashable {
    let windowID: CGWindowID
    let pid: pid_t
    let title: String
}

func trustedChrome(_ pid: pid_t) -> Bool {
    let attrs = [kSecGuestAttributePid: pid] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
    var requirement: SecRequirement?
    let text = "identifier \"com.google.Chrome\" and anchor apple generic and certificate leaf[subject.OU] = \"EQHXZ8M8AV\""
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}

func candidateSnapshot() -> [Candidate]? {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
    let pids = Set(apps.map(\.processIdentifier))
    guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
    var result: [Candidate] = []
    for w in windows {
        guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
              let title = w[kCGWindowName as String] as? String, Product.titles.contains(title),
              let id = w[kCGWindowNumber as String] as? UInt32,
              trustedChrome(pid) else { continue }
        result.append(Candidate(windowID: id, pid: pid, title: title))
    }
    return result
}

func candidates() -> [Candidate] { candidateSnapshot() ?? [] }

func axValue(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, key as CFString, &result) == .success else { return nil }
    return result
}
func axText(_ e: AXUIElement, _ key: String) -> String { axValue(e, key) as? String ?? "" }
func axChildren(_ e: AXUIElement) -> [AXUIElement] { axValue(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

func expectedBody(_ text: String) -> Bool {
    text.contains("外部应用请求完全控制此 Chrome 会话") ||
        (text.lowercased().contains("external app") && text.lowercased().contains("chrome session") && text.lowercased().contains("control"))
}

enum DialogPresence: String { case present, absent, unavailable }

struct AuthorizationNode<Element> {
    let role: String
    var subrole = ""
    var title: String?
    var children: [Element]?
}

func scanAuthorizationDialogs<Element>(windows: [Element], title: String,
                                      read: (Element) -> AuthorizationNode<Element>?,
                                      uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                                      failure: (String) -> Void = { _ in }) -> [Element]? {
    var dialogs: [Element] = []
    var pending = windows.map { ($0, 0) }
    var budget = 256
    let deadline = uptime() + 0.7
    while let (element, depth) = pending.popLast() {
        guard budget > 0 else { failure("node_budget_exceeded"); return nil }
        guard uptime() < deadline else { failure("deadline_exceeded"); return nil }
        guard let node = read(element), !node.role.isEmpty else { failure("node_unreadable"); return nil }
        guard uptime() < deadline else { failure("deadline_exceeded"); return nil }
        budget -= 1
        if node.role == kAXSheetRole || node.subrole == kAXDialogSubrole {
            guard let dialogTitle = node.title else { failure("dialog_title_unreadable"); return nil }
            if dialogTitle == title { dialogs.append(element) }
        } else if [kAXGroupRole, kAXWindowRole].contains(node.role) {
            guard let children = node.children else { failure("children_unreadable"); return nil }
            guard depth < 16 || children.isEmpty else { failure("depth_exceeded"); return nil }
            pending += children.map { ($0, depth + 1) }
        }
    }
    return dialogs
}

func authorizationDialogs(_ candidate: Candidate, failure: (String) -> Void = { _ in }) -> [AXUIElement]? {
    guard trustedChrome(candidate.pid) else { failure("chrome_identity_unavailable"); return nil }
    let app = AXUIElementCreateApplication(candidate.pid)
    AXUIElementSetMessagingTimeout(app, 0.08)
    func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { failure("\(attribute):\(error.rawValue)"); return nil }
        return value
    }
    guard let windows = read(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
    return scanAuthorizationDialogs(windows: windows, title: candidate.title, read: { element in
        guard let role = read(element, kAXRoleAttribute) as? String else { return nil }
        var node = AuthorizationNode<AXUIElement>(role: role)
        if [kAXWindowRole, kAXGroupRole].contains(role) {
            var subrole: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if error == .success {
                guard let text = subrole as? String else { return nil }
                node.subrole = text
            } else if error != .attributeUnsupported && error != .noValue {
                failure("\(kAXSubroleAttribute):\(error.rawValue)"); return nil
            }
        }
        if role == kAXSheetRole || node.subrole == kAXDialogSubrole {
            node.title = read(element, kAXTitleAttribute) as? String
        } else if [kAXWindowRole, kAXGroupRole].contains(role) {
            node.children = read(element, kAXChildrenAttribute) as? [AXUIElement]
        }
        return node
    }, failure: failure)
}

func authorizationPresence(_ candidate: Candidate) -> DialogPresence {
    guard let dialogs = authorizationDialogs(candidate) else { return .unavailable }
    return dialogs.isEmpty ? .absent : .present
}

func authorizationDiagnostics(_ candidate: Candidate, presence: DialogPresence, clickSent: Bool? = nil) -> [String: Any] {
    let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]
    let window = windows?.first { $0[kCGWindowNumber as String] as? UInt32 == candidate.windowID }
    var failures: [String] = []
    if presence == .unavailable { _ = authorizationDialogs(candidate, failure: { failures.append($0) }) }
    return ["windowID": candidate.windowID, "pid": candidate.pid, "clickSent": clickSent.map { $0 as Any } ?? NSNull(),
            "windowQueryAvailable": windows != nil,
            "windowExists": window != nil, "onscreen": window?[kCGWindowIsOnscreen as String] ?? NSNull(),
            "alpha": window?[kCGWindowAlpha as String] ?? NSNull(), "dialogPresence": presence.rawValue,
            "scanFailures": failures]
}

func authorizationButton(_ candidate: Candidate) -> AXUIElement? {
    guard let dialogs = authorizationDialogs(candidate) else { return nil }
    var matches: [AXUIElement] = []
    for dialog in dialogs {
        var queue = [dialog]
        var remaining = 200
        var body = false
        var allow: [AXUIElement] = []
        var cancel = 0
        while let e = queue.popLast(), remaining > 0 {
            remaining -= 1
            let role = axText(e, kAXRoleAttribute)
            if role == kAXStaticTextRole { body = body || expectedBody(axText(e, kAXValueAttribute) + axText(e, kAXTitleAttribute)) }
            if role == kAXButtonRole {
                let title = axText(e, kAXTitleAttribute)
                if ["允许", "Allow"].contains(title) { allow.append(e) }
                if ["取消", "Cancel"].contains(title) { cancel += 1 }
            }
            if role != "AXWebArea" { queue += axChildren(e) }
        }
        if body && cancel == 1 && allow.count == 1 { matches += allow }
    }
    guard matches.count == 1, axValue(matches[0], kAXEnabledAttribute) as? Bool == true else { return nil }
    return matches[0]
}

func clickAuthorization(_ candidate: Candidate) -> Bool {
    guard candidates() == [candidate], let button = authorizationButton(candidate) else { return false }
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    record("authorization_action", ["windowID": candidate.windowID, "axError": result.rawValue])
    return result == .success
}

final class SingleUseLease {
    private let lock = NSLock()
    private var deadline: TimeInterval = 0
    private var used = false
    func arm(seconds: Double = 4) {
        lock.lock(); defer { lock.unlock() }
        deadline = ProcessInfo.processInfo.systemUptime + min(max(seconds, 0), 4)
        used = false
    }
    func revoke() { lock.lock(); deadline = 0; lock.unlock() }
    func consume(eligible: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard eligible, !used, ProcessInfo.processInfo.systemUptime < deadline else { return false }
        used = true; deadline = 0
        return true
    }
}

func clientRequest(_ text: String, owner: Int) -> String? {
    let fields = text.trimmingCharacters(in: .newlines).split(separator: " ", omittingEmptySubsequences: false)
    guard fields.count == 3, fields[0] == "CONSUME", Int(fields[1]) == owner,
          fields[2].count == 32, fields[2].allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
    return String(fields[2])
}

func childProcess(mode: String, args: [String] = []) throws -> (Process, Pipe) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = Bundle.main.executableURL
    process.arguments = [mode, String(getpid())] + args
    process.standardInput = pipe
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return (process, pipe)
}

func ownParent(_ expected: Int32) -> Bool { cc_parent_is_app(expected) == 1 }

import Foundation

struct OperationResult: Codable, Equatable {
    let id: UUID
    let time: Date
    let success: Bool
    let locked: Bool
    let message: String

    init(id: UUID = UUID(), time: Date = Date(), success: Bool, locked: Bool, message: String) {
        self.id = id; self.time = time; self.success = success; self.locked = locked; self.message = message
    }
}

struct RunState: Codable {
    var monitoring = true
    var successCount = 0
    var recent: [OperationResult] = []
    var pending: PendingOperation?

    mutating func append(_ result: OperationResult) {
        guard !recent.contains(where: { $0.id == result.id }) else { return }
        recent.insert(result, at: 0)
        if pending?.id == result.id { pending = nil }
        recent = Array(recent.prefix(50))
        if result.success { successCount += 1 }
    }
}

struct PendingOperation: Codable { let id: UUID; let locked: Bool }

func guardianResultMessage(_ reason: String) -> String {
    switch reason {
    case "unlock_not_confirmed", "login_submit_unavailable": return "未能完成临时解锁，已结束本次处理"
    case "login_ui_not_ready", "login_wake_unavailable", "login_display_unavailable": return "系统登录界面未就绪，未提交解锁认证"
    case "login_field_not_empty": return "密码输入框非空或无法确认，已停止自动处理"
    case "login_field_unavailable", "login_focus_unavailable", "login_field_changed", "login_process_changed": return "系统登录界面发生变化，已停止自动处理"
    case "plugin_not_contacted": return "已发送提交按键，但认证组件未收到请求"
    case "plugin_denied": return "认证组件未批准本次临时解锁"
    case "unexpected_unlock": return "检测到非本次认证产生的解锁，已停止自动处理"
    case "external_input": return "检测到用户操作，已停止自动处理"
    case "parent_channel_closed": return "处理已停止，并恢复锁屏"
    case "dialog_timeout", "dialog_changed": return "授权窗口发生变化或未能关闭"
    case "window_query_unavailable": return "无法读取授权窗口，请检查屏幕录制权限"
    case "input_monitor_disabled", "guardian_exit_4": return "输入保护不可用，未完成处理"
    case "guardian_exit_7", "shield_not_ready", "display_configuration_changed": return "锁屏保护画面不可用或显示器发生变化，已停止处理"
    case "guardian_exit_3", "prepare_changed": return "运行条件发生变化，未完成处理"
    default: return "锁屏处理未完成，请查看日志"
    }
}

final class RunStateStore {
    private let defaults: UserDefaults
    private(set) var state: RunState
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "runState"), let saved = try? JSONDecoder().decode(RunState.self, from: data) {
            state = saved
        } else { state = RunState() }
    }
    func setMonitoring(_ enabled: Bool) { state.monitoring = enabled; save() }
    func begin(id: UUID, locked: Bool) { state.pending = PendingOperation(id: id, locked: locked); save() }
    func recoverInterrupted() {
        if let pending = state.pending {
            append(OperationResult(id: pending.id, success: false, locked: pending.locked, message: "上次处理被中断，请查看日志"))
        }
    }
    func append(_ result: OperationResult) { state.append(result); save() }
    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: "runState") }
    }
}

enum ClickProgress: Equatable { case waiting, succeeded, timedOut, interrupted }

struct DismissalTracker {
    private var absentSince: TimeInterval?
    private(set) var evidence: String?
    mutating func observe(sent: Bool, targetPresent: Bool?, dialog: DialogPresence, now: TimeInterval) -> Bool {
        evidence = nil
        guard sent, let targetPresent else { absentSince = nil; return false }
        if !targetPresent { evidence = "window_removed"; return true }
        guard dialog == .absent else { absentSince = nil; return false }
        if let absentSince, now - absentSince >= 0.3 { evidence = "controls_removed"; return true }
        if absentSince == nil { absentSince = now }
        return false
    }
}

struct ClickAttempt {
    var id = UUID()
    let target: Candidate
    let started: TimeInterval
    var sent = false
    var tries = 0
    var lastTry: TimeInterval = -.infinity
    var dismissal = DismissalTracker()
    mutating func progress(now: TimeInterval, present: [Candidate]?, permissions: Bool, unlocked: Bool, chromeRunning: Bool,
                          dialog: DialogPresence = .unavailable) -> ClickProgress {
        guard permissions, unlocked, chromeRunning else { return .interrupted }
        if dismissal.observe(sent: sent, targetPresent: present.map { $0.contains(target) }, dialog: dialog, now: now) { return .succeeded }
        if now - started >= 5 { return .timedOut }
        return .waiting
    }
}

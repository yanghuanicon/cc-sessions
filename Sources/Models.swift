import Foundation

/// 开着的会话所处的状态，决定它出现在面板的哪一组。
enum LiveState: Int {
    case waiting = 0
    case busy = 1
    case idle = 2
}

/// 会话跑在哪里，决定点击后怎么跳转。
enum SessionHost: Equatable {
    /// 终端里的交互式会话，tty 形如 /dev/ttys001；拿不到 tty 时为 nil。
    case terminal(tty: String?)
    /// `claude --bg` 启动的后台会话，跳转时用 `claude attach <shortId>`。
    case background(shortId: String)
    /// Claude 桌面端里的会话，不在终端中。
    case desktop
    /// 由程序通过 SDK 拉起的会话（如飞书机器人），没有终端。
    case sdk
}

struct LiveSession: Identifiable {
    let id: String
    let pid: Int32?
    var name: String
    let cwd: String
    let state: LiveState
    let host: SessionHost
    let updatedAt: Date
    var branch: String?
    /// 等你处理时在等什么，来自登记表的 waitingFor（如 input needed）。
    var waitingFor: String? = nil

    var waitingReason: String? {
        guard state == .waiting else { return nil }
        let raw = (waitingFor ?? "").lowercased()
        if raw.contains("permission") || raw.contains("approv") { return "等你授权" }
        if raw.contains("input") || raw.isEmpty { return "等你回复" }
        return waitingFor
    }
}

/// 一个历史会话在索引里的全部信息，来自 ~/.claude/projects 下的 jsonl。
struct HistoryEntry: Identifiable, Codable {
    let id: String
    let path: String
    var cwd: String = ""
    var branch: String = ""
    var customTitle: String = ""
    var aiTitle: String = ""
    var firstPrompt: String = ""
    var lastReply: String = ""
    var turns: Int = 0
    /// cli 是终端里开的；sdk-cli 等是程序拉起的（claude -p、飞书机器人）。
    var entrypoint: String = ""
    var modifiedAt: Date = .distantPast
    var size: UInt64 = 0
    /// 已解析到的字节位置；jsonl 只追加，下次只读新增部分。
    var offset: UInt64 = 0
    /// 用于全文检索的文本，只保留最近的一段，避免内存膨胀。
    var searchText: String = ""

    var isProgrammatic: Bool { entrypoint.hasPrefix("sdk") }

    var title: String {
        if !customTitle.isEmpty { return customTitle }
        if !aiTitle.isEmpty { return aiTitle }
        if !firstPrompt.isEmpty { return String(firstPrompt.prefix(40)) }
        return String(id.prefix(8))
    }
}

enum Format {
    static let home = NSHomeDirectory()

    static func shortDir(_ path: String) -> String {
        if path.isEmpty { return "—" }
        if path == home { return "~" }
        let name = (path as NSString).lastPathComponent
        return path.hasPrefix(home + "/") && path.components(separatedBy: "/").count <= 4 ? "~/" + name : name
    }

    static func tildePath(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60))分" }
        if seconds < 86400 { return "\(Int(seconds / 3600))小时" }
        let days = Int(seconds / 86400)
        return days == 1 ? "昨天" : "\(days)天前"
    }

    /// 单引号包裹，供拼 shell 命令用。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

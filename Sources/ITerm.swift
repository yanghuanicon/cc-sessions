import Foundation

/// 通过 AppleScript 操作 iTerm2：按 tty 找到会话并切过去、新开标签页执行命令、往会话里输入文字。
enum ITerm {
    enum Result: Equatable {
        case ok
        case notFound
        case failed(String)
    }

    /// 切到 tty 对应的那个 iTerm 会话（窗口、标签页、分屏都会选中）。
    static func focus(tty: String) -> Result {
        run("""
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(escape(tty))" then
                            select w
                            tell t to select
                            tell s to select
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "notfound"
        end tell
        """)
    }

    /// 新开一个标签页执行命令；没有窗口时新建窗口。
    static func openTab(command: String) -> Result {
        run("""
        tell application "iTerm2"
            activate
            if (count of windows) = 0 then
                create window with default profile
            else
                tell current window to create tab with default profile
            end if
            tell current session of current window to write text "\(escape(command))"
            return "ok"
        end tell
        """)
    }

    /// 往 tty 对应的会话里输入一行文字（带回车）。
    static func send(text: String, tty: String) -> Result {
        run("""
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(escape(tty))" then
                            tell s to write text "\(escape(text))"
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "notfound"
        end tell
        """)
    }

    private static func run(_ source: String) -> Result {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failed("脚本无法创建") }
        let output = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743：用户没允许本工具控制 iTerm。
            return .failed(code == -1743 ? "没有控制 iTerm 的权限，请在「系统设置 → 隐私与安全性 → 自动化」里允许" : message)
        }
        return output.stringValue == "notfound" ? .notFound : .ok
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

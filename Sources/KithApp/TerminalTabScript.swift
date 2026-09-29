/// AppleScript that brings the window and tab owning a tty, passed as the only argument, to the front.
/// Only Terminal and iTerm2 expose each tab's tty to scripts.
enum TerminalTabScript {
    static let byBundleID: [String: String] = [
        // Terminal can list a transient window that has no tabs, so each window is tried on its own.
        "com.apple.Terminal": """
            on run {target}
                tell application id "com.apple.Terminal"
                    repeat with w in (get windows)
                        try
                            set t to first tab of w whose tty is target
                            set miniaturized of w to false
                            set selected of t to true
                            set index of w to 1
                            return
                        end try
                    end repeat
                end tell
            end run
            """,
        "com.googlecode.iterm2": """
            on run {target}
                tell application id "com.googlecode.iterm2"
                    repeat with w in (get windows)
                        repeat with t in (get tabs of w)
                            repeat with s in (get sessions of t)
                                if tty of s is target then
                                    select s
                                    select t
                                    select w
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
            end run
            """
    ]
}

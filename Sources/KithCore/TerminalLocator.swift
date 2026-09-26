import AppKit
import Darwin
import Foundation

public enum TerminalLocator {
    private static let terminalIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "org.wezfurlong.wezterm",
        "net.kovidgoyal.kitty", "io.alacritty"
    ]

    public static func bundleID(startingAt pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<16 where current > 1 {
            if let bundle = NSRunningApplication(processIdentifier: current)?.bundleIdentifier,
               terminalIDs.contains(bundle) { return bundle }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
                  size > 0 else { return nil }
            current = info.kp_eproc.e_ppid
        }
        return nil
    }
}

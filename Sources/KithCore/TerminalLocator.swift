import AppKit
import Darwin
import Foundation

public struct TerminalLocation: Sendable {
    public let bundleID: String
    /// The owning tab's device, such as /dev/ttys003.
    public let tty: String?
}

public enum TerminalLocator {
    private static let terminalIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "org.wezfurlong.wezterm",
        "net.kovidgoyal.kitty", "io.alacritty"
    ]

    public static func locate(startingAt pid: pid_t) -> TerminalLocation? {
        var current = pid
        var tty: String?
        for _ in 0..<16 where current > 1 {
            if let bundle = NSRunningApplication(processIdentifier: current)?.bundleIdentifier,
               terminalIDs.contains(bundle) { return TerminalLocation(bundleID: bundle, tty: tty) }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
                  size > 0 else { return nil }
            // Hooks run without a controlling terminal, so the tab's tty is the first one up the tree.
            if tty == nil, let name = devname(info.kp_eproc.e_tdev, S_IFCHR) {
                tty = "/dev/" + String(cString: name)
            }
            current = info.kp_eproc.e_ppid
        }
        return nil
    }
}

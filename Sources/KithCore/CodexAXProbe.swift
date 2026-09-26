import AppKit
@preconcurrency import ApplicationServices
import Foundation

public enum CodexAXProbe {
    public static var trusted: Bool { AXIsProcessTrusted() }

    public static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Returns nil when Accessibility cannot inspect the Desktop app.
    public static func hasInteractivePrompt() -> Bool? {
        guard trusted else { return nil }
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.openai.codex").first else { return false }
        let root = AXUIElementCreateApplication(application.processIdentifier)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows) == .success,
              let windows = windows as? [AXUIElement] else { return nil }
        for window in windows {
            var buttonTitles = Set<String>()
            var budget = 500
            collectButtons(in: window, depth: 0, budget: &budget, titles: &buttonTitles)
            let hasApproval = !buttonTitles.isDisjoint(with: ["allow", "approve", "always allow"]) &&
                !buttonTitles.isDisjoint(with: ["deny", "reject", "cancel"])
            let hasQuestion = buttonTitles.contains("submit") &&
                !buttonTitles.isDisjoint(with: ["skip", "answer", "cancel"])
            if hasApproval || hasQuestion { return true }
            if budget == 0 { return nil }
        }
        return false
    }

    private static func collectButtons(in element: AXUIElement, depth: Int, budget: inout Int,
                                       titles: inout Set<String>) {
        guard depth < 8, budget > 0 else { return }
        budget -= 1
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let role = role as? String, role == kAXButtonRole as String {
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
               let title = title as? String { titles.insert(title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let children = children as? [AXUIElement] else { return }
        for child in children.prefix(100) {
            collectButtons(in: child, depth: depth + 1, budget: &budget, titles: &titles)
        }
    }
}

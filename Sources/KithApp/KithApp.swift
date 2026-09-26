import AppKit
import SwiftUI

@main
struct KithApp: App {
    @StateObject private var model = KithModel()

    var body: some Scene {
        MenuBarExtra {
            KithMenu().environmentObject(model)
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: KithMenuBarIcon.image)
                    .renderingMode(.template)
                if model.countdown != nil {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .semibold))
                } else if model.attentionCount > 0 {
                    Text(model.attentionCount > 9 ? "9+" : "\(model.attentionCount)")
                        .font(.system(size: 10, weight: .semibold))
                } else if model.hasMonitoringIssue {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                } else if model.runningCount > 0 {
                    Circle().frame(width: 5, height: 5)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(menuBarLabel)
        }
        .menuBarExtraStyle(.window)

        Window("Kith", id: "workspace") {
            KithWorkspaceWindow().environmentObject(model)
        }
        .defaultSize(width: 720, height: 560)

    }

    private var menuBarLabel: String {
        if let action = model.armedAction, let countdown = model.countdown {
            return "Kith will \(action.rawValue) in \(countdown) seconds. Open to cancel."
        }
        if model.attentionCount > 0 {
            return "Kith: \(model.attentionCount) sessions need attention"
        }
        if model.hasMonitoringIssue { return "Kith: session monitoring needs attention" }
        if !model.monitoringReady { return "Kith: checking session status" }
        if model.runningCount > 0 { return "Kith: \(model.runningCount) sessions working" }
        return "Kith: all caught up"
    }
}

@MainActor
enum KithMenuBarIcon {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "KithMenuBarTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "moon.stars", accessibilityDescription: "Kith") ?? NSImage()
    }()
}

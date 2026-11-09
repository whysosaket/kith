import AppKit
import Foundation
import KithCore
import ServiceManagement

@MainActor
final class WorkflowSettings: ObservableObject {
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginMessage: String?
    @Published private(set) var checkingUpdates = false
    @Published private(set) var updateMessage = "Updates are checked only when requested."
    @Published private(set) var releaseURL: URL?
    @Published private(set) var browserWarnings: [String] = []
    private var browserCheck: Task<Void, Never>?
    private var lastBrowserCheck = Date.distantPast
    private var lastLoginInstall: String?

    var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown" }

    func refreshLogin() {
        guard !KithTesting.enabled else { return }
        let file = Bundle.main.executableURL
        let modified = file.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let install = (file?.path ?? "") + ":" + String(modified?.timeIntervalSince1970 ?? 0)
        if launchAtLogin, SMAppService.mainApp.status == .enabled, let previous = lastLoginInstall, previous != install {
            do { try SMAppService.mainApp.register() }
            catch { loginMessage = "App changed. Review Launch Kith at login: " + error.localizedDescription }
        }
        lastLoginInstall = install
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginMessage = SMAppService.mainApp.status == .requiresApproval ? "Approve Kith in System Settings → General → Login Items & Extensions." : nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLogin()
        } catch { refreshLogin(); loginMessage = error.localizedDescription }
    }

    func checkUpdates() {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        releaseURL = nil
        updateMessage = "Checking for updates…"
        Task {
            defer { checkingUpdates = false }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/whysosaket/kith/releases/latest")!)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Kith-update-check", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 1_048_576 else {
                    throw PowerError.unavailable("The release service could not provide an update. Try again later.")
                }
                let release = try JSONDecoder().decode(KithRelease.self, from: data)
                guard !release.draft, !release.prerelease,
                      let latest = ReleaseVersion(release.tag_name), let installed = ReleaseVersion(version),
                      let url = URL(string: release.html_url), url.scheme == "https", url.host == "github.com",
                      url.path.hasPrefix("/whysosaket/kith/releases/tag/") else {
                    throw PowerError.unavailable("The release service returned an unexpected release")
                }
                if latest > installed {
                    releaseURL = url
                    updateMessage = "Kith \(release.tag_name) is available."
                } else { updateMessage = "You have the latest stable version."
                }
            } catch { updateMessage = error.localizedDescription }
        }
    }

    func refreshBrowsers(enabled: Bool) {
        guard enabled else { browserWarnings = []; return }
        guard browserCheck == nil, Date().timeIntervalSince(lastBrowserCheck) >= 30 else { return }
        lastBrowserCheck = Date()
        let supported: Set<String> = ["com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac",
            "com.brave.Browser", "company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"]
        let browsers = NSWorkspace.shared.runningApplications.compactMap { app -> (Int32, String)? in
            guard let id = app.bundleIdentifier, supported.contains(id) else { return nil }
            return (app.processIdentifier, app.localizedName ?? id)
        }
        browserCheck = Task {
            let warnings = await Task.detached(priority: .utility) {
                let commands = BoundedCommand()
                return browsers.compactMap { pid, name -> String? in
                    guard let result = try? commands.run("/bin/ps", ["-p", String(pid), "-o", "command="], timeout: 2),
                          result.status == 0, !result.output.isEmpty else { return "\(name): launch options could not be checked." }
                    let required = ["--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding"]
                    return required.allSatisfy(result.output.contains) ? nil : "\(name) may throttle hidden windows. Test browser-driven work before leaving it unattended."
                }
            }.value
            browserWarnings = warnings
            browserCheck = nil
        }
    }
}

private struct KithRelease: Decodable {
    var tag_name: String
    var html_url: String
    var draft: Bool
    var prerelease: Bool
}

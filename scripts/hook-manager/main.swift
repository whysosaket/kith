import Foundation

guard CommandLine.arguments.count == 3,
      ["install", "uninstall", "status"].contains(CommandLine.arguments[1]) else {
    fputs("Usage: manage-hooks.sh install|uninstall|status /path/to/kith-event\n", stderr)
    exit(2)
}

let command = CommandLine.arguments[1]
let executable = URL(fileURLWithPath: CommandLine.arguments[2])
guard FileManager.default.isExecutableFile(atPath: executable.path) else {
    fputs("kith-event is not executable at the supplied path\n", stderr)
    exit(2)
}

do {
    switch command {
    case "install": try HookInstaller.install(executable: executable)
    case "uninstall": try HookInstaller.uninstall(executable: executable)
    default: break
    }
    print(HookInstaller.isInstalled(executable: executable) ? "Kith hooks installed" : "Kith hooks not installed")
} catch {
    fputs("Hook update failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

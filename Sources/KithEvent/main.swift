import Foundation
import KithCore

guard CommandLine.arguments.count == 2,
      let source = AgentSource(rawValue: CommandLine.arguments[1]) else { exit(0) }
let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= 1_000_000,
      let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
      let event = EventParser.parse(source: source, payload: payload,
                                    terminalBundleID: TerminalLocator.bundleID(startingAt: getppid())) else { exit(0) }
if !EventSocket.send(event) { try? EventSpool.enqueue(event) }

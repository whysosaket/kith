import Foundation

public enum EventParser {
    public static func parse(source: AgentSource, payload: [String: Any],
                             terminal: TerminalLocation? = nil) -> AgentEvent? {
        guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty,
              let name = payload["hook_event_name"] as? String else { return nil }
        let turnID = payload["turn_id"] as? String
        let projectPath = payload["cwd"] as? String
        let attentionID = payload["tool_use_id"] as? String
        let toolName = payload["tool_name"] as? String
        let kind: AgentEventKind
        var detail: String?

        switch name {
        case "SessionStart": kind = .sessionStarted
        case "UserPromptSubmit": kind = .turnStarted
        case "PermissionRequest":
            kind = .attentionOpened
            detail = toolName.map { "Approve \($0)" } ?? "Waiting for approval"
        case "Stop": kind = .stopCandidate
        case "StopFailure": kind = .turnFailed
        case "Interrupt": kind = .interrupted
        case "SessionEnd": kind = .sessionEnded
        case "PreToolUse" where source == .claude &&
            toolName == "AskUserQuestion":
            kind = .attentionOpened
            detail = "Has a question for you"
        case "PostToolUse":
            kind = .attentionResolved
        case "Notification" where source == .claude:
            let notification = payload["notification_type"] as? String
            switch notification {
            case "permission_prompt":
                kind = .attentionOpened
                detail = "Waiting for approval"
            case "elicitation_dialog", "elicitation_url_dialog":
                kind = .attentionOpened
                detail = "Has a question for you"
            case "agent_needs_input":
                kind = .attentionOpened
                detail = "Waiting for your reply"
            case "quota_auto_resume_stale":
                kind = .attentionOpened
                detail = "Paused on usage limit"
            case "elicitation_complete", "elicitation_response": kind = .attentionResolved
            case "idle_prompt", "agent_completed": kind = .stopCandidate
            case "quota_auto_resume_fired": kind = .turnStarted
            case "quota_auto_resume_disabled":
                kind = .turnFailed
                detail = "Usage limit reached"
            default: return nil
            }
        default: return nil
        }

        let tasks = payload["background_tasks"] as? [[String: Any]] ?? []
        let hasBackgroundWork = tasks.contains { ($0["status"] as? String) == "running" }
        return AgentEvent(source: source, sessionID: sessionID, turnID: turnID,
                          kind: kind, projectPath: projectPath,
                          attentionID: attentionID, hasBackgroundWork: hasBackgroundWork,
                          terminalBundleID: terminal?.bundleID, terminalTTY: terminal?.tty,
                          detail: detail)
    }
}

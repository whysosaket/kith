import Foundation

public enum EventParser {
    public static func parse(source: AgentSource, payload: [String: Any],
                             terminalBundleID: String? = nil) -> AgentEvent? {
        guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty,
              let name = payload["hook_event_name"] as? String else { return nil }
        let turnID = payload["turn_id"] as? String
        let projectPath = payload["cwd"] as? String
        let attentionID = payload["tool_use_id"] as? String
        let kind: AgentEventKind

        switch name {
        case "SessionStart": kind = .sessionStarted
        case "UserPromptSubmit": kind = .turnStarted
        case "PermissionRequest": kind = .attentionOpened
        case "Stop": kind = .stopCandidate
        case "StopFailure": kind = .turnFailed
        case "Interrupt": kind = .interrupted
        case "SessionEnd": kind = .sessionEnded
        case "PreToolUse" where source == .claude &&
            (payload["tool_name"] as? String) == "AskUserQuestion":
            kind = .attentionOpened
        case "PostToolUse":
            kind = .attentionResolved
        case "Notification" where source == .claude:
            let notification = payload["notification_type"] as? String
            switch notification {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog",
                 "agent_needs_input", "quota_auto_resume_stale": kind = .attentionOpened
            case "elicitation_complete", "elicitation_response": kind = .attentionResolved
            case "idle_prompt", "agent_completed": kind = .stopCandidate
            case "quota_auto_resume_fired": kind = .turnStarted
            case "quota_auto_resume_disabled": kind = .turnFailed
            default: return nil
            }
        default: return nil
        }

        let tasks = payload["background_tasks"] as? [[String: Any]] ?? []
        let hasBackgroundWork = tasks.contains { ($0["status"] as? String) == "running" }
        return AgentEvent(source: source, sessionID: sessionID, turnID: turnID,
                          kind: kind, projectPath: projectPath,
                          attentionID: attentionID, hasBackgroundWork: hasBackgroundWork,
                          terminalBundleID: terminalBundleID)
    }
}

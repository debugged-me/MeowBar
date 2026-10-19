import Foundation

// "Is a Devin turn running?" from the Devin app's ACP session log. The agent
// (`devin acp`) idles at ~0% CPU while the model works server-side, so CPU
// can't tell; the log can. During a turn a row lands every few seconds
// (thoughts, messages, tool calls), and a tool call has no status or
// "in_progress" until it finishes. When the turn ends, the last row is the
// final message and the log goes quiet.
enum DevinActivity {
    struct Row: Equatable {
        var kind: String       // agent_message, agent_thought, tool_call, plan, user_message
        var status: String?    // tool_call only: pending / in_progress / completed / failed
    }

    // After a message the turn has likely ended; after a thought or a tool
    // step the next step may take a while to start streaming.
    static let quietAfterMessage: TimeInterval = 20
    static let quietMidTurn: TimeInterval = 45

    // rows: newest first. quiet: seconds since the log was last written.
    static func isActive(rows: [Row], quietFor quiet: TimeInterval) -> Bool {
        guard let last = rows.first else { return false }
        let toolRunning = rows.contains {
            $0.kind == "tool_call" && $0.status != "completed" && $0.status != "failed"
        }
        if toolRunning { return true }
        return quiet < (last.kind == "agent_message" ? quietAfterMessage : quietMidTurn)
    }
}

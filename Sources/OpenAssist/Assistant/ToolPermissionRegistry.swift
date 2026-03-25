import Foundation

// MARK: - Permission Model

enum AgentPermission: String, CaseIterable, Sendable {
    case appleEvents
    case fullDiskAccess
    case browserAutomation
    case browserProfile
    case computerUseEnabled
    case accessibility
    case screenRecording

    var displayName: String {
        switch self {
        case .appleEvents: return "Apple Events / Automation"
        case .fullDiskAccess: return "Full Disk Access"
        case .browserAutomation: return "Browser Automation (enabled in settings)"
        case .browserProfile: return "Browser Profile (selected in settings)"
        case .computerUseEnabled: return "Computer Use (enabled in settings)"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        }
    }
}

struct ToolPermissionRequirement: Sendable {
    let toolName: String
    let required: Set<AgentPermission>
    let optional: Set<AgentPermission>
}

struct ToolPermissionVerdict: Sendable {
    let satisfied: Bool
    let missing: [AgentPermission]
    let message: String
}

// MARK: - Registry

enum ToolPermissionRegistry {

    @MainActor
    static func snapshot(using settings: SettingsStore) -> PermissionSnapshot {
        let pc = PermissionCenter.snapshot(using: settings)
        return PermissionSnapshot(
            accessibilityGranted: pc.accessibilityGranted,
            screenRecordingGranted: pc.screenRecordingGranted,
            appleEventsGranted: pc.appleEventsGranted,
            appleEventsKnown: pc.appleEventsKnown,
            fullDiskAccessGranted: pc.fullDiskAccessGranted,
            browserAutomationEnabled: settings.browserAutomationEnabled,
            browserProfileSelected: !settings.browserSelectedProfileID
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            computerUseEnabled: settings.assistantComputerUseEnabled
        )
    }

    /// Base requirements for each dynamic tool. `requirements(forToolName:arguments:)`
    /// may promote optional permissions to required based on parsed arguments.
    static let requirements: [ToolPermissionRequirement] = [
        ToolPermissionRequirement(
            toolName: "browser_use",
            required: [.browserAutomation, .browserProfile],
            optional: [.appleEvents]
        ),
        ToolPermissionRequirement(
            toolName: "app_action",
            required: [],
            optional: [.appleEvents]
        ),
        ToolPermissionRequirement(
            toolName: "computer_use",
            required: [.computerUseEnabled, .accessibility, .screenRecording],
            optional: []
        ),
        ToolPermissionRequirement(
            toolName: "generate_image",
            required: [],
            optional: []
        ),
        ToolPermissionRequirement(
            toolName: "exec_command",
            required: [],
            optional: []
        ),
        ToolPermissionRequirement(
            toolName: "write_stdin",
            required: [],
            optional: []
        ),
        ToolPermissionRequirement(
            toolName: "read_terminal",
            required: [],
            optional: []
        ),
        ToolPermissionRequirement(
            toolName: "view_image",
            required: [],
            optional: []
        ),
        ToolPermissionRequirement(
            toolName: "screen_capture",
            required: [.screenRecording],
            optional: []
        ),
        ToolPermissionRequirement(
            toolName: "window_list",
            required: [],
            optional: []
        ),
        ToolPermissionRequirement(
            toolName: "window_capture",
            required: [.screenRecording],
            optional: []
        ),
        ToolPermissionRequirement(
            toolName: "ui_inspect",
            required: [.accessibility],
            optional: []
        ),
        ToolPermissionRequirement(
            toolName: "ui_click",
            required: [.accessibility],
            optional: []
        ),
        ToolPermissionRequirement(
            toolName: "ui_type",
            required: [.accessibility],
            optional: []
        ),
        ToolPermissionRequirement(
            toolName: "ui_press_key",
            required: [.accessibility],
            optional: []
        )
    ]

    /// Returns the effective requirement for a tool call, promoting optional→required
    /// for `app_action` when the parsed arguments target Terminal or Calendar (which use AppleScript).
    static func requirements(forToolName toolName: String, arguments: Any?) -> ToolPermissionRequirement? {
        guard var base = requirements.first(where: { $0.toolName == toolName }) else {
            return nil
        }

        if toolName == "app_action", let arguments {
            if let parsed = try? AssistantAppActionService.parseRequest(from: arguments) {
                switch parsed.app {
                case .terminal:
                    var promoted = base.required
                    promoted.insert(.appleEvents)
                    var remaining = base.optional
                    remaining.remove(.appleEvents)
                    base = ToolPermissionRequirement(
                        toolName: toolName,
                        required: promoted,
                        optional: remaining
                    )
                default:
                    break
                }
            }
        }

        return base
    }

    // MARK: - Verification

    /// Snapshot of live permission state used by the registry for verification.
    /// Decoupled from `PermissionCenter.Snapshot` so callers build it from whatever source they have.
    struct PermissionSnapshot: Sendable {
        let accessibilityGranted: Bool
        let screenRecordingGranted: Bool
        let appleEventsGranted: Bool
        let appleEventsKnown: Bool
        let fullDiskAccessGranted: Bool
        let browserAutomationEnabled: Bool
        let browserProfileSelected: Bool
        let computerUseEnabled: Bool
    }

    static func verify(
        toolName: String,
        arguments: Any?,
        snapshot: PermissionSnapshot
    ) -> ToolPermissionVerdict {
        guard let req = requirements(forToolName: toolName, arguments: arguments) else {
            return ToolPermissionVerdict(satisfied: true, missing: [], message: "")
        }

        var missing: [AgentPermission] = []
        for perm in req.required {
            if !isGranted(perm, in: snapshot) {
                missing.append(perm)
            }
        }

        if missing.isEmpty {
            return ToolPermissionVerdict(satisfied: true, missing: [], message: "")
        }

        let toolDisplay = toolName.replacingOccurrences(of: "_", with: " ").capitalized
        let message = permissionGuidanceMessage(
            toolName: toolName,
            toolDisplay: toolDisplay,
            missing: missing
        )
        return ToolPermissionVerdict(satisfied: false, missing: missing, message: message)
    }

    private static func isGranted(_ permission: AgentPermission, in snapshot: PermissionSnapshot) -> Bool {
        switch permission {
        case .accessibility: return snapshot.accessibilityGranted
        case .screenRecording: return snapshot.screenRecordingGranted
        case .appleEvents: return snapshot.appleEventsGranted
        case .fullDiskAccess: return snapshot.fullDiskAccessGranted
        case .browserAutomation: return snapshot.browserAutomationEnabled
        case .browserProfile: return snapshot.browserProfileSelected
        case .computerUseEnabled: return snapshot.computerUseEnabled
        }
    }

    // MARK: - Instruction Generation

    /// Generates the dynamic system prompt section describing permission state and tool availability.
    static func instructionBlock(snapshot: PermissionSnapshot) -> String {
        var lines: [String] = []
        lines.append("# macOS Permission State")
        lines.append("")
        lines.append("| Permission | Status |")
        lines.append("|---|---|")
        lines.append("| Accessibility | \(yesNo(snapshot.accessibilityGranted)) |")
        lines.append("| Screen Recording | \(yesNo(snapshot.screenRecordingGranted)) |")
        lines.append("| Apple Events / Automation | \(appleEventsStatus(snapshot)) |")
        lines.append("| Full Disk Access | \(yesNo(snapshot.fullDiskAccessGranted)) |")
        lines.append("| Browser Automation | \(yesNo(snapshot.browserAutomationEnabled)) |")
        lines.append("| Browser Profile | \(yesNo(snapshot.browserProfileSelected)) |")
        lines.append("| Computer Use | \(yesNo(snapshot.computerUseEnabled)) |")
        lines.append("")

        // Tool availability summary
        lines.append("## Tool Availability")
        lines.append("")
        for req in requirements {
            let verdict = verify(toolName: req.toolName, arguments: nil, snapshot: snapshot)
            let toolDisplay = req.toolName.replacingOccurrences(of: "_", with: " ").capitalized
            if verdict.satisfied {
                lines.append("- **\(toolDisplay)**: AVAILABLE")
            } else {
                let names = verdict.missing.map(\.displayName).joined(separator: ", ")
                lines.append("- **\(toolDisplay)**: UNAVAILABLE — needs \(names)")
            }
        }
        lines.append("")

        // Dynamic osascript/AppleScript guidance
        lines.append("## macOS Automation Guidelines")
        lines.append("")

        // CRITICAL: Privacy-protected apps blocklist — must appear first and be unambiguous
        lines.append("""
        ### BLOCKED: Privacy-Protected Apps

        The following Apple apps are protected by macOS privacy controls. You MUST NOT attempt to interact with them via `osascript`, AppleScript, shell commands, `tell application`, reading their data files, or any other scripting method:

        **Mail, Photos, Safari, Music, TV, Podcasts, Home, Health**

        Note: Reminders, Calendar, Contacts, Notes, and Messages are now accessible via the `app_action` tool using native frameworks — no osascript needed.

        Any attempt to use osascript against the blocked apps listed above — including `osascript -e 'tell application ...'`, reading their `~/Library/` data files, `sqlite3` on their databases, `shortcuts run`, or heredoc AppleScript — will either:
        - Hang indefinitely waiting for a macOS permission dialog that cannot be dismissed from the terminal, OR
        - Fail with "Operation not permitted"

        There is NO workaround. Do NOT retry with different syntax, shell wrappers, or file-level access. When the user asks about these apps, immediately tell them that Open Assist cannot access that app's data due to macOS privacy restrictions, and suggest they open the app manually.
        """)
        lines.append("")

        if !snapshot.fullDiskAccessGranted {
            lines.append("""
            ### Full Disk Access: NOT Granted

            Reading app data files under `~/Library/` (e.g. `~/Library/Reminders/`, `~/Library/Calendars/`, `~/Library/Messages/`) will fail with "Operation not permitted". Do NOT attempt file-level workarounds for blocked apps.
            """)
            lines.append("")
        }

        if snapshot.appleEventsGranted {
            lines.append("""
            ### Allowed osascript Targets

            Apple Events permission is granted. You may use `osascript` ONLY for these safe targets: Finder, Terminal, System Events, and non-Apple apps that are already authorized. \
            For everything else, use the `app_action` tool or tell the user the app is off-limits.
            """)
        } else {
            lines.append("""
            ### osascript Fully Disabled

            Apple Events / Automation permission is NOT granted. NEVER use `osascript` or AppleScript to talk to ANY app — the call will hang indefinitely. \
            Use the `app_action` tool for Finder, Terminal, Calendar, and System Settings. For all other apps, tell the user you cannot script them and suggest they grant Automation permission to Open Assist first.
            """)
        }
        lines.append("")
        lines.append("""
        ### Supported App Actions

        The `app_action` tool supports these apps directly — use it instead of osascript:
        - **Reminders**: list, add, complete, fetch overdue. Use app="Reminders".
        - **Calendar**: read events, create events. Use app="Calendar".
        - **Contacts**: search by name. Use app="Contacts" with a query.
        - **Notes**: search and read notes. Use app="Notes" with a query.
        - **Messages/iMessage**: read recent messages, search, list chats. Use app="Messages". Requires Full Disk Access.
        - **Finder**: open/reveal files and folders.
        - **Terminal**: run shell commands.
        - **System Settings**: open settings panes.

        For Mail, Photos, Safari, Music, and other blocked apps, tell the user Open Assist cannot access them.
        """)
        lines.append("")
        lines.append("""
        ### Computer Use

        The `computer_use` tool is for generic visual desktop interaction when `browser_use` and `app_action` are not enough. It needs Computer Use enabled in Settings plus Accessibility and Screen Recording permissions. Use `computer_use` only for screenshot-based observe, click, drag, scroll, keypress, type, or wait steps on the visible desktop.
        """ )
        lines.append("")
        lines.append("""
        ### Shell And Window Tools

        The `exec_command`, `write_stdin`, and `read_terminal` tools run local shell work and continue interactive sessions on this Mac. The `view_image` tool loads a local image file. The `screen_capture` and `window_capture` tools need Screen Recording because they capture pixels from the current desktop.
        """)
        lines.append("")
        lines.append("""
        ### Accessibility UI Tools

        The `ui_inspect`, `ui_click`, `ui_type`, and `ui_press_key` tools use macOS Accessibility APIs to inspect app controls, focus fields, click elements, and send keys without relying only on screenshot coordinates.
        """)

        return lines.joined(separator: "\n")
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "YES" : "NO"
    }

    private static func appleEventsStatus(_ snapshot: PermissionSnapshot) -> String {
        if !snapshot.appleEventsKnown { return "UNKNOWN" }
        return snapshot.appleEventsGranted ? "YES" : "NO"
    }

    private static func permissionGuidanceMessage(
        toolName: String,
        toolDisplay: String,
        missing: [AgentPermission]
    ) -> String {
        let names = missing.map(\.displayName).joined(separator: ", ")
        var nextSteps: [String] = []

        switch toolName {
        case "browser_use":
            if missing.contains(.browserAutomation) {
                nextSteps.append("Turn on Browser Automation in Settings > Automation.")
            }
            if missing.contains(.browserProfile) {
                nextSteps.append("Choose a Browser Profile in Settings > Automation.")
            }
        case "app_action":
            if missing.contains(.appleEvents) {
                nextSteps.append("Grant Automation if macOS asks for it.")
            }
            if missing.contains(.fullDiskAccess) {
                nextSteps.append("Grant Full Disk Access only if the requested app data needs it.")
            }
        case "computer_use":
            if missing.contains(.computerUseEnabled) {
                nextSteps.append("Turn on Computer Use in Settings > Automation.")
            }
            if missing.contains(.accessibility) {
                nextSteps.append("Grant Accessibility so Open Assist can click and type.")
            }
            if missing.contains(.screenRecording) {
                nextSteps.append("Grant Screen Recording so Open Assist can capture the current screen.")
            }
        case "screen_capture", "window_capture":
            if missing.contains(.screenRecording) {
                nextSteps.append("Grant Screen Recording so Open Assist can capture the current screen or window.")
            }
        case "ui_inspect", "ui_click", "ui_type", "ui_press_key":
            if missing.contains(.accessibility) {
                nextSteps.append("Grant Accessibility so Open Assist can inspect and control macOS UI elements.")
            }
        default:
            break
        }

        if nextSteps.isEmpty {
            return "\(toolDisplay) cannot run because these permissions are missing: \(names)."
        }

        return "\(toolDisplay) cannot run because these permissions are missing: \(names). Next step: \(nextSteps.joined(separator: " "))"
    }
}

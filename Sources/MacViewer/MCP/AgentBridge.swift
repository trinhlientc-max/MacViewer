import AppKit
import Combine
import Foundation
import ImageIO
import UltraViewerProtocol
import UniformTypeIdentifiers

struct AgentActivity: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let client: String
    let tool: String
    let detail: String
    let isError: Bool
}

/// The MCP client a tool call is running for (set around `AgentBridge.run`),
/// so every helper acts on that client's own remote computer.
enum AgentCallContext {
    @TaskLocal static var client: UUID?
}

/// A session an agent is attached to, without keeping a closed tab alive.
struct WeakConnection {
    weak var model: ConnectionModel?
}

/// The support windows MacViewer opened on one remote computer.
struct ConsoleWindows {
    var normal: String?
    var admin: String?
}

struct ShellFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Lets AI agents use the current remote session through MCP. Off by default;
/// every tool respects the permissions chosen in Settings › AI Agents.
@MainActor
final class AgentBridge: ObservableObject, MCPToolHost {
    static let enabledKey = "MacViewer.mcp.enabled"
    static let allowScreenKey = "MacViewer.mcp.allowScreen"
    static let allowInputKey = "MacViewer.mcp.allowInput"
    static let allowConnectKey = "MacViewer.mcp.allowConnect"
    static let allowCommandsKey = "MacViewer.mcp.allowCommands"
    static let askFirstKey = "MacViewer.mcp.askFirst"
    static let trustedClientsKey = "MacViewer.mcp.trustedClients"

    enum Approval { case once, always, deny }
    struct PendingApproval: Identifiable, Equatable {
        let id: UUID
        let client: MCPClientInfo
    }

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Self.enabledKey); applyEnabled() } }
    @Published var allowScreen: Bool { didSet { defaults.set(allowScreen, forKey: Self.allowScreenKey) } }
    @Published var allowInput: Bool { didSet { defaults.set(allowInput, forKey: Self.allowInputKey) } }
    @Published var allowConnect: Bool { didSet { defaults.set(allowConnect, forKey: Self.allowConnectKey) } }
    @Published var allowCommands: Bool { didSet { defaults.set(allowCommands, forKey: Self.allowCommandsKey) } }
    @Published var askFirst: Bool { didSet { defaults.set(askFirst, forKey: Self.askFirstKey) } }
    @Published private(set) var trustedClients: [String]
    @Published private(set) var isListening = false
    @Published private(set) var listenError: String?
    @Published private(set) var connectedClients: [MCPSocketServer.ConnectionID: String] = [:]
    @Published private(set) var activity: [AgentActivity] = []
    /// True for a few seconds after an agent sent input, to show the badge.
    @Published private(set) var isActing = false
    @Published private(set) var pendingApproval: PendingApproval?
    /// Set by Stop; agent input is refused until this remote session ends.
    @Published private(set) var isStoppedForSession = false

    private let sessionList: SessionsModel
    /// Each agent stays on the computer it first worked on (or last chose with
    /// `connect`), whatever tab the user shows, so several agents can support
    /// several computers at once without taking each other's sessions.
    private var bindings: [UUID: WeakConnection] = [:]
    private var model: ConnectionModel {
        guard let token = AgentCallContext.client else { return sessionList.current }
        if let bound = bindings[token] {
            if let model = bound.model, sessionList.sessions.contains(where: { $0 === model }) { return model }
            // Its session was closed: never fall through to another computer.
            return sessionList.form
        }
        let model = sessionList.current
        if model.isSessionActive { bindings[token] = WeakConnection(model: model) }
        return model
    }
    private let defaults: UserDefaults
    private let server: MCPSocketServer
    private var sessions: [MCPSocketServer.ConnectionID: MCPSession] = [:]
    private var queues: [MCPSocketServer.ConnectionID: AsyncStream<String>.Continuation] = [:]
    private var approvedThisRun: Set<String> = []
    /// Waiters are bound to one pending approval id so a dialog action can only
    /// complete the client it was shown for.
    private var approvalWaiters: [UUID: CheckedContinuation<Approval, Never>] = [:]
    private var approvalQueue = MCPApprovalQueue<MCPClientInfo>()
    private var actingTask: Task<Void, Never>?
    private var phaseObserver: AnyCancellable?
    /// Screenshot pixels per remote pixel, per MCP client session, because each
    /// client may request a different screenshot width.
    private var clientScales = MCPClientScale()
    /// Replies from remote PowerShell scripts, keyed by `MCPRemoteShell.key`.
    private var shellInbox: [String: String] = [:]
    /// Channels started in this app run; replies for other ids are dropped.
    private var shellChannels: [String] = []
    /// Support windows (by their loop id) opened in this app run.
    private var consoleChannels: Set<String> = []
    /// The visible support windows open on each remote computer.
    private var consoles: [ObjectIdentifier: ConsoleWindows] = [:]
    /// Support window → command it is still running, and the reverse.
    private var consoleBusy: [String: String] = [:]
    private var commandWindow: [String: String] = [:]
    /// Command ids that answered anything (pickup, ack, chunk or result), and
    /// those that finished. A result can be taken from the inbox by a waiting
    /// caller before `dispatch` looks, so finishing is remembered here.
    private var heardFrom: Set<String> = []
    private var finished: Set<String> = []

    init(sessions: SessionsModel, defaults: UserDefaults = .standard, server: MCPSocketServer = MCPSocketServer()) {
        self.sessionList = sessions
        self.defaults = defaults
        self.server = server
        defaults.register(defaults: [Self.enabledKey: false, Self.allowScreenKey: true, Self.allowInputKey: false,
                                     Self.allowConnectKey: false, Self.allowCommandsKey: false,
                                     Self.askFirstKey: true])
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        allowScreen = defaults.bool(forKey: Self.allowScreenKey)
        allowInput = defaults.bool(forKey: Self.allowInputKey)
        allowConnect = defaults.bool(forKey: Self.allowConnectKey)
        allowCommands = defaults.bool(forKey: Self.allowCommandsKey)
        askFirst = defaults.bool(forKey: Self.askFirstKey)
        trustedClients = defaults.stringArray(forKey: Self.trustedClientsKey) ?? []
        server.onConnect = { [weak self] id, program in Task { @MainActor in self?.opened(id, program: program) } }
        server.onLine = { [weak self] id, line in Task { @MainActor in self?.queues[id]?.yield(line) } }
        server.onClose = { [weak self] id in Task { @MainActor in self?.closed(id) } }
        phaseObserver = sessionList.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.sessionList.hasActiveSession else { return }
                self.isStoppedForSession = false
            }
        }
    }

    /// Starts listening when enabled. Call once the app has launched.
    func start() { applyEnabled() }

    func shutdown() {
        server.stop()
        isListening = false
    }

    private func applyEnabled() {
        if isEnabled {
            guard !server.isRunning else { return }
            do { try server.start(); isListening = true; listenError = nil }
            catch { isListening = false; listenError = error.localizedDescription }
        } else {
            server.stop()
            isListening = false
            listenError = nil
            for continuation in queues.values { continuation.finish() }
            queues = [:]; sessions = [:]; connectedClients = [:]
            cancelApprovals(ids: approvalQueue.cancelAll())
        }
    }

    // MARK: Connections

    private func opened(_ id: MCPSocketServer.ConnectionID, program: String?) {
        guard isEnabled else { server.disconnect(id); return }
        let session = MCPSession(host: self, program: program)
        sessions[id] = session
        connectedClients[id] = MCPClientInfo.unknown.name
        let (stream, continuation) = AsyncStream<String>.makeStream()
        queues[id] = continuation
        Task { [weak self] in
            for await line in stream {
                guard let self else { return }
                if let response = await session.handle(line) { server.send(response, to: id) }
                if connectedClients[id] != nil { connectedClients[id] = session.client.name }
            }
        }
    }

    private func closed(_ id: MCPSocketServer.ConnectionID) {
        let token = sessions[id]?.client.sessionToken
        if let token { bindings[token] = nil }
        queues.removeValue(forKey: id)?.finish()
        sessions[id] = nil
        connectedClients[id] = nil
        if let token { cancelApprovals(forSessionTokens: [token]) }
    }

    /// Disconnects every agent and refuses every tool except `session_status`
    /// until this remote session ends.
    func stopAgents() {
        server.disconnectAll()
        approvedThisRun = []
        isStoppedForSession = model.isSessionActive
        isActing = false
        cancelAllPendingApprovals()
        record(client: L("You"), tool: "stop", detail: L("Stopped all AI agents."), isError: false)
    }

    func clearActivity() { activity = [] }

    func untrust(_ client: String) {
        trustedClients.removeAll { $0 == client }
        defaults.set(trustedClients, forKey: Self.trustedClientsKey)
    }

    // MARK: Approval

    /// Resolves exactly the approval the dialog is currently showing. A second
    /// invoke (double click / keyboard race) is ignored, and a denial can be
    /// asked again, so no client is blocked for the rest of the app run.
    func resolveApproval(_ decision: Approval) {
        guard let pending = pendingApproval else { return }
        guard let client = approvalQueue.resolve(pending.id),
              let waiter = approvalWaiters.removeValue(forKey: pending.id) else {
            showNextApproval()
            return
        }
        let key = client.trustKey
        switch decision {
        case .once:
            approvedThisRun.insert(key)
        case .always:
            approvedThisRun.insert(key)
            if !trustedClients.contains(key) {
                trustedClients.append(key)
                defaults.set(trustedClients, forKey: Self.trustedClientsKey)
            }
        case .deny:
            break
        }
        showNextApproval()
        waiter.resume(returning: decision)
    }

    private func showNextApproval() {
        pendingApproval = approvalQueue.pending.map { PendingApproval(id: $0.id, client: $0.client) }
    }

    private func cancelApprovals(ids: [UUID]) {
        for id in ids {
            approvalWaiters.removeValue(forKey: id)?.resume(returning: .deny)
        }
        showNextApproval()
    }

    private func cancelApprovals(forSessionTokens tokens: Set<UUID>) {
        cancelApprovals(ids: approvalQueue.cancel { tokens.contains($0.sessionToken) })
    }

    private func cancelAllPendingApprovals() {
        cancelApprovals(ids: approvalQueue.cancelAll())
    }

    private func isApproved(_ client: MCPClientInfo) async -> Bool {
        guard askFirst else { return true }
        let key = client.trustKey
        if approvedThisRun.contains(key) || trustedClients.contains(key) { return true }
        let id = UUID()
        let decision = await withCheckedContinuation { continuation in
            approvalWaiters[id] = continuation
            approvalQueue.enqueue(client, id: id)
            showNextApproval()
            NSApp.activateApp()
        }
        return decision != .deny
    }

    // MARK: Tools

    private var toolPermissions: MCPToolGate.Permissions {
        MCPToolGate.Permissions(screen: allowScreen, input: allowInput, connect: allowConnect,
                                commands: allowCommands, stoppedForSession: isStoppedForSession)
    }

    func callTool(_ name: String, arguments: JSONValue, client: MCPClientInfo) async -> MCPToolResult {
        guard isEnabled else { return .error("AI agents are turned off in MacViewer › Settings › AI Agents.") }
        if let refusal = MCPToolGate.refusal(tool: name, permissions: toolPermissions) {
            record(client: client.name, tool: name, detail: refusal, isError: true)
            return .error(refusal)
        }
        guard await isApproved(client) else {
            record(client: client.name, tool: name, detail: "Declined by the user.", isError: true)
            return .error("The MacViewer user declined access for \(client.name).")
        }
        // Permissions or Stop can change while the approval dialog is open.
        if let refusal = MCPToolGate.refusal(tool: name, permissions: toolPermissions) {
            record(client: client.name, tool: name, detail: refusal, isError: true)
            return .error(refusal)
        }
        let result = await AgentCallContext.$client.withValue(client.sessionToken) {
            await run(name, arguments, client: client)
        }
        let detail = result.content.first?["text"]?.stringValue.map { String($0.prefix(140)) } ?? ""
        record(client: client.name, tool: name, detail: detail, isError: result.isError)
        return result
    }

    private func record(client: String, tool: String, detail: String, isError: Bool) {
        activity.insert(AgentActivity(client: client, tool: tool, detail: detail, isError: isError), at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
    }

    private func run(_ name: String, _ arguments: JSONValue, client: MCPClientInfo) async -> MCPToolResult {
        switch name {
        case "session_status": return status()
        case "connect": return await connect(arguments)
        case "disconnect":
            guard allowConnect else { return .error(MCPToolGate.connectDenied) }
            guard model.isSessionActive else { return .text("There is no active session.") }
            sessionList.close(model)
            return .text("Disconnected.")
        case "screenshot": return await screenshot(arguments, client: client)
        case "select_monitor":
            guard model.phase == .connected else { return .error(Self.notConnected) }
            let index = arguments["index"]?.intValue ?? 0
            guard index == 0 || model.remoteInfo?.monitors.contains(where: { $0.index == index }) == true else {
                return .error("There is no monitor \(index). See session_status.")
            }
            model.selectMonitor(index)
            // Screenshots taken before this switch belong to the old image size.
            clientScales.reset()
            return .text(index == 0 ? "Showing all monitors. Take a new screenshot." : "Showing monitor \(index). Take a new screenshot.")
        case "click", "move_mouse", "drag", "scroll", "type_text", "press_keys", "remote_action":
            if let refusal = inputRefusal() { return .error(refusal) }
            return input(name, arguments, client: client)
        case "send_chat":
            guard model.phase == .connected, model.tools.isActive else { return .error(Self.notConnected) }
            guard let text = arguments["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error("Give the message text.")
            }
            model.tools.draft = text
            model.tools.sendDraft()
            return .text("Message sent.")
        case "read_chat":
            let limit = max(1, arguments["limit"]?.intValue ?? 20)
            let lines = model.tools.messages.suffix(limit).map { ($0.isOutgoing ? "Me: " : "Remote: ") + $0.text }
            return .text(lines.isEmpty ? "No chat messages in this session." : lines.joined(separator: "\n"))
        case "set_clipboard":
            guard model.phase == .connected else { return .error(Self.notConnected) }
            guard model.tools.clipboardEnabled else {
                return .error("Clipboard sharing is off for this session. Ask the user to turn it on in the session toolbar.")
            }
            guard let text = arguments["text"]?.stringValue else { return .error("Give the text to share.") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            await model.tools.pollClipboardOnce()
            return .text("The text is on the shared clipboard. Paste it on the remote computer with press_keys \"ctrl+v\".")
        case "run_command": return await runCommand(arguments)
        case "command_result": return await commandResult(arguments)
        case "put_file": return await putFile(arguments)
        case "get_file": return await getFile(arguments)
        case "get_clipboard":
            guard let entry = model.tools.clipboardHistory.first(where: { !$0.isOutgoing }) else {
                return .text("Nothing has been copied on the remote computer in this session.")
            }
            return .text(entry.text)
        default:
            return .error("Unknown tool \(name).")
        }
    }

    private static let notConnected = "MacViewer is not connected to a remote computer. Ask the user to connect, or use connect."

    private func status() -> MCPToolResult {
        var text = Self.statusText(for: model, allowScreen: allowScreen,
                                   allowInput: allowInput, allowConnect: allowConnect, allowCommands: allowCommands)
        let mine = model
        let open = sessionList.activeSessions.map { session -> String in
            let name = session.remoteInfo?.displayName ?? session.partnerID
            let id = session.remoteInfo?.partnerID ?? session.partnerID
            return "\(name) (ID \(id))" + (session === mine ? " ← this agent" : "")
        }
        if !open.isEmpty {
            text += "\nOpen sessions: " + open.joined(separator: "; ") +
                "\nThis agent always acts on its own session above; use connect with another partner ID to switch."
        }
        if mine === sessionList.form, let token = AgentCallContext.client, bindings[token] != nil {
            text += "\nThis agent's session was closed. Use connect to start or join a session."
        }
        return .text(text)
    }

    /// The text behind the `session_status` tool. Kept separate so its content
    /// (including `monitorNotice`) is testable without starting the MCP server.
    @MainActor
    static func statusText(for model: ConnectionModel, allowScreen: Bool,
                           allowInput: Bool, allowConnect: Bool, allowCommands: Bool = false) -> String {
        var lines = ["Phase: \(model.phase.title)"]
        if let info = model.remoteInfo {
            lines.append("Partner: \(info.displayName ?? info.partnerID) (ID \(info.partnerID))")
            lines.append("Remote allows control: \(info.allowsRemoteInput ? "yes" : "no")")
            lines.append("Control switched on in MacViewer: \(model.controlEnabled ? "yes" : "no")")
            for monitor in info.monitors {
                lines.append("Monitor \(monitor.index): \(monitor.width)×\(monitor.height)")
            }
            lines.append("Selected monitor: \(model.selectedMonitor == 0 ? "all" : String(model.selectedMonitor))")
            if let notice = model.monitorNotice { lines.append("Monitor notice: \(notice)") }
            if let image = model.displayedFrame?.image { lines.append("Screen size: \(image.width)×\(image.height)") }
            lines.append("Clipboard sharing: \(model.tools.clipboardEnabled ? "on" : "off")")
        } else {
            lines.append("Status: \(model.status)")
        }
        lines.append("Agents may: view screen \(allowScreen ? "yes" : "no"), control \(allowInput ? "yes" : "no"), connect/disconnect \(allowConnect ? "yes" : "no"), run commands \(allowCommands ? "yes" : "no")")
        if !model.recentPartners.isEmpty { lines.append("Recent partner IDs: \(model.recentPartners.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    private func connect(_ arguments: JSONValue) async -> MCPToolResult {
        guard allowConnect else { return .error(MCPToolGate.connectDenied) }
        let identifier = (arguments["partner_id"]?.stringValue ?? "").filter { !$0.isWhitespace && $0 != "-" }
        guard !identifier.isEmpty else { return .error("Give the partner ID.") }
        guard let model = sessionList.connect(partnerID: identifier,
                                           password: arguments["password"]?.stringValue ?? "",
                                           showExisting: false) else {
            return .error(L(sessionList.formError ?? "No password is saved for \(identifier) on this Mac. Pass the password."))
        }
        if let token = AgentCallContext.client { bindings[token] = WeakConnection(model: model) }
        for _ in 0..<450 where model.phase == .connecting {
            try? await Task.sleep(seconds: 0.1)
        }
        switch model.phase {
        case .connected:
            return .text("Connected to \(model.remoteInfo?.displayName ?? identifier). Control is \(model.controlEnabled ? "on" : "off"); the user may need to switch it on.")
        case .connecting:
            return .text("Still connecting. Check again with session_status.")
        default:
            return .error(L(model.errorMessage ?? model.status))
        }
    }

    private func screenshot(_ arguments: JSONValue, client: MCPClientInfo) async -> MCPToolResult {
        guard model.phase == .connected else { return .error(Self.notConnected) }
        for _ in 0..<30 where model.displayedFrame == nil { try? await Task.sleep(seconds: 0.1) }
        guard let image = model.displayedFrame?.image else { return .error("No screen image has arrived yet. Try again.") }
        let maxWidth = max(320, arguments["max_width"]?.intValue ?? 1280)
        guard let encoded = Self.jpeg(image, maxWidth: maxWidth) else { return .error("The screenshot could not be encoded.") }
        clientScales.record(Double(encoded.width) / Double(image.width), for: client.sessionToken)
        return MCPToolResult(content: [
            ["type": "image", "data": .string(encoded.data.base64EncodedString()), "mimeType": "image/jpeg"],
            ["type": "text", "text": .string("Screenshot \(encoded.width)×\(encoded.height) of a \(image.width)×\(image.height) remote screen. Use this image's pixel coordinates for mouse tools.")],
        ])
    }

    static func jpeg(_ image: CGImage, maxWidth: Int) -> (data: Data, width: Int, height: Int)? {
        let scale = min(1, Double(maxWidth) / Double(image.width))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var output = image
        if scale < 1 {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            output = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, width, height)
    }

    private func inputRefusal() -> String? {
        guard model.phase == .connected else { return Self.notConnected }
        guard model.remoteInfo?.allowsRemoteInput == true else { return "The remote computer allows viewing only." }
        guard model.controlEnabled else {
            return "Control is off. Ask the user to switch on Control in the MacViewer session toolbar."
        }
        return nil
    }

    /// Converts screenshot coordinates to remote pixels in the displayed frame,
    /// using the scale of the client that took the screenshot.
    func remotePoint(x: Int, y: Int, for session: UUID) -> (x: Int, y: Int) {
        guard let image = model.displayedFrame?.image else {
            return (max(0, x), max(0, y))
        }
        return clientScales.point(x: x, y: y, imageWidth: image.width,
                                  imageHeight: image.height, session: session)
    }

    private static func button(_ name: String?) -> Int? {
        switch name ?? "left" {
        case "left": 0
        case "right": 1
        case "middle": 2
        default: nil
        }
    }

    private func input(_ name: String, _ arguments: JSONValue, client: MCPClientInfo) -> MCPToolResult {
        func point(_ xKey: String, _ yKey: String) -> (x: Int, y: Int)? {
            guard let x = arguments[xKey]?.intValue, let y = arguments[yKey]?.intValue else { return nil }
            return remotePoint(x: x, y: y, for: client.sessionToken)
        }
        var events = [RemoteInput]()
        let summary: String
        switch name {
        case "click":
            guard let target = point("x", "y") else { return .error("Give x and y.") }
            guard let button = Self.button(arguments["button"]?.stringValue) else { return .error("Unknown button.") }
            let count = min(3, max(1, arguments["count"]?.intValue ?? 1))
            events.append(.pointerMoved(x: target.x, y: target.y))
            if count >= 2 {
                // The dedicated 0x203/0x206/0x209 wire message; the peer
                // synthesises the press/release pair.
                events.append(.doubleClick(button: button, x: target.x, y: target.y))
            }
            if count == 1 || count == 3 {
                events.append(.pointerButton(button: button, pressed: true, x: target.x, y: target.y))
                events.append(.pointerButton(button: button, pressed: false, x: target.x, y: target.y))
            }
            summary = count == 2
                ? "Double-clicked at \(target.x),\(target.y) on the remote screen."
                : "Clicked at \(target.x),\(target.y) on the remote screen."
        case "move_mouse":
            guard let target = point("x", "y") else { return .error("Give x and y.") }
            events.append(.pointerMoved(x: target.x, y: target.y))
            summary = "Moved to \(target.x),\(target.y)."
        case "drag":
            guard let start = point("from_x", "from_y"), let end = point("to_x", "to_y") else {
                return .error("Give from_x, from_y, to_x and to_y.")
            }
            guard let button = Self.button(arguments["button"]?.stringValue) else { return .error("Unknown button.") }
            events.append(.pointerMoved(x: start.x, y: start.y))
            events.append(.pointerButton(button: button, pressed: true, x: start.x, y: start.y))
            let steps = 12
            for step in 1...steps {
                let fraction = Double(step) / Double(steps)
                events.append(.pointerMoved(x: start.x + Int(Double(end.x - start.x) * fraction),
                                            y: start.y + Int(Double(end.y - start.y) * fraction)))
            }
            events.append(.pointerButton(button: button, pressed: false, x: end.x, y: end.y))
            summary = "Dragged from \(start.x),\(start.y) to \(end.x),\(end.y)."
        case "scroll":
            let amount = min(50, max(1, arguments["amount"]?.intValue ?? 3))
            let direction = arguments["direction"]?.stringValue ?? "down"
            guard direction == "up" || direction == "down" else { return .error("direction must be up or down.") }
            if let target = point("x", "y") {
                events.append(.pointerMoved(x: target.x, y: target.y))
            } else if let image = model.displayedFrame?.image,
                      let anchor = MCPWheelAnchor.point(cursor: model.remoteCursor?.position,
                                                        imageWidth: image.width,
                                                        imageHeight: image.height) {
                // The peer routes its wheel by the transmitted position; a move
                // first keeps a wheel without coordinates under the pointer
                // instead of at virtual-desktop (0,0).
                events.append(.pointerMoved(x: anchor.x, y: anchor.y))
            } else {
                return .error("No remote screen is shown yet. Give x and y to scroll at a known point.")
            }
            events.append(.scroll(deltaX: 0, deltaY: Double(direction == "up" ? amount : -amount)))
            summary = "Scrolled \(direction) \(amount)."
        case "type_text":
            guard let text = arguments["text"]?.stringValue, !text.isEmpty else { return .error("Give the text to type.") }
            guard text.count <= 10_000 else { return .error("Type at most 10,000 characters at a time.") }
            let plan = MCPKeys.typingPlan(for: text)
            events = plan.events
            summary = plan.skippedUnits == 0
                ? "Typed \(text.count) characters."
                : "Typed \(plan.sentUnits) of \(plan.totalUnits) UTF-16 units; \(plan.skippedUnits) units (emoji or control characters) cannot be typed as VK_PACKET."
        case "press_keys":
            guard let keys = arguments["keys"]?.stringValue else { return .error("Give the keys to press.") }
            do {
                let chords = try MCPKeys.parse(keys)
                let repeatCount = min(100, max(1, arguments["repeat"]?.intValue ?? 1))
                for _ in 0..<repeatCount { for chord in chords { events += MCPKeys.events(for: chord) } }
            } catch { return .error(error.localizedDescription) }
            summary = "Pressed \(keys)."
        case "remote_action":
            switch arguments["action"]?.stringValue {
            case "ctrl_alt_delete":
                model.releaseRemoteInput()
                model.performRemoteAction(.controlAltDelete)
                markActing()
                return .text("Sent Ctrl-Alt-Delete.")
            case "lock_screen":
                model.releaseRemoteInput()
                model.performRemoteAction(.lockScreen)
                markActing()
                return .text("Locked the remote screen.")
            default: return .error("action must be ctrl_alt_delete or lock_screen.")
            }
        default:
            return .error("Unknown tool \(name).")
        }
        for event in events { model.sendAgentInput(event) }
        markActing()
        return .text(summary)
    }

    // MARK: Commands and files (Windows, over the shared clipboard)

    private func runCommand(_ arguments: JSONValue) async -> MCPToolResult {
        guard let script = arguments["script"]?.stringValue,
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error("Give the PowerShell script to run.")
        }
        let timeout = Double(min(600, max(5, arguments["timeout"]?.intValue ?? 60)))
        let admin = arguments["admin"]?.boolValue ?? false
        let note = arguments["note"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? MCPRemoteShell.defaultNote
        let id = MCPRemoteShell.newID()
        if let error = await launch(id: id, script: script, admin: admin, note: note) { return .error(error) }
        let key = MCPRemoteShell.key(id: id, verb: "res", index: nil)
        switch await waitForShell([key], timeout: admin ? min(timeout, 15) : timeout) {
        case let .received(_, payload):
            return Self.commandText(payload)
        case let .stopped(reason):
            return .error(reason)
        case .timedOut:
            return .text("""
            No result yet (command_id \(id)). \(admin
                ? "Windows is probably asking (UAC) to open the administrator support window: take a screenshot, click Yes, then call command_result."
                : "It is still running in the support window: call command_result to keep waiting (tell the person how long with send_chat if it takes a while).")
            """)
        }
    }

    private func commandResult(_ arguments: JSONValue) async -> MCPToolResult {
        guard let id = arguments["command_id"]?.stringValue, shellChannels.contains(id) else {
            return .error("Unknown command_id.")
        }
        guard Self.isConnected(model) else { return .error(Self.notConnected) }
        let timeout = Double(min(600, max(1, arguments["timeout"]?.intValue ?? 30)))
        switch await waitForShell([MCPRemoteShell.key(id: id, verb: "res", index: nil)], timeout: timeout) {
        case let .received(_, payload): return Self.commandText(payload)
        case let .stopped(reason): return .error(reason)
        case .timedOut: return .text("Still no result for \(id). Take a screenshot to see what is happening.")
        }
    }

    private static func isConnected(_ model: ConnectionModel) -> Bool { model.phase == .connected }

    private static func commandText(_ payload: String) -> MCPToolResult {
        let result = MCPRemoteShell.splitResult(payload)
        let header = "Exit code: \(result.exitCode.map(String.init) ?? "unknown")"
        let body = result.output.isEmpty ? "(no output)" : result.output
        return MCPToolResult(content: [["type": "text", "text": .string(header + "\n" + body)]],
                             isError: (result.exitCode ?? 0) != 0)
    }

    private func putFile(_ arguments: JSONValue) async -> MCPToolResult {
        guard let localPath = arguments["local_path"]?.stringValue, !localPath.isEmpty,
              let remotePath = arguments["remote_path"]?.stringValue, !remotePath.isEmpty else {
            return .error("Give local_path (on this Mac) and remote_path (full Windows path).")
        }
        let url = URL(fileURLWithPath: (localPath as NSString).expandingTildeInPath)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
            .flatMap({ $0.isRegularFile == true ? $0.fileSize : nil }) else {
            return .error("\(url.path) is not a file on this Mac.")
        }
        guard size <= MCPRemoteShell.maxFileBytes else { return .error("Files larger than 200 MB are not supported.") }
        let parts: [String]
        do { parts = MCPRemoteShell.chunks(try MCPRemoteShell.encode(Data(contentsOf: url))) }
        catch { return .error("\(url.path) could not be read.") }

        let id = MCPRemoteShell.newID()
        let script = MCPRemoteShell.putScript(id: id, remotePath: remotePath,
                                              overwrite: arguments["overwrite"]?.boolValue ?? false)
        let name = MCPRemoteShell.fileName(ofRemotePath: remotePath)
        if let error = await launch(id: id, script: script, admin: false,
                                    note: "Đang chép tệp vào máy: \(name) / Copying a file to this computer") { return .error(error) }
        let result = MCPRemoteShell.key(id: id, verb: "res", index: nil)
        var expected = MCPRemoteShell.key(id: id, verb: "ack", index: -1)
        for (index, part) in parts.enumerated() {
            switch await waitForShell([expected, result], timeout: index == 0 ? 30 : 60) {
            case let .received(key, payload) where key == result: return Self.commandText(payload)
            case .received: break
            case let .stopped(reason): return .error(reason)
            case .timedOut:
                return .error(index == 0
                    ? "The remote script did not start. Take a screenshot: the Run box may not have opened."
                    : "The remote computer stopped answering after part \(index) of \(parts.count).")
            }
            do { try await model.tools.sendAgentClipboard("MVR-\(id)|put|\(index)|\(parts.count)|\(part)") }
            catch { return .error("Part \(index + 1) could not be sent over the shared clipboard.") }
            expected = MCPRemoteShell.key(id: id, verb: "ack", index: index)
        }
        switch await waitForShell([result], timeout: 60) {
        case let .received(_, payload): return Self.commandText(payload)
        case let .stopped(reason): return .error(reason)
        case .timedOut: return .error("Sent every part, but the remote script did not confirm. Check with run_command.")
        }
    }

    private func getFile(_ arguments: JSONValue) async -> MCPToolResult {
        guard let remotePath = arguments["remote_path"]?.stringValue, !remotePath.isEmpty else {
            return .error("Give remote_path, the full path of the file on the Windows computer.")
        }
        let id = MCPRemoteShell.newID()
        let name = MCPRemoteShell.fileName(ofRemotePath: remotePath)
        if let error = await launch(id: id, script: MCPRemoteShell.getScript(id: id, remotePath: remotePath), admin: false,
                                    note: "Đang gửi tệp cho kỹ thuật viên xem: \(name) / Sending a file to the technician") {
            return .error(error)
        }
        let result = MCPRemoteShell.key(id: id, verb: "res", index: nil)
        var encoded = ""
        var index = 0, total = 1
        while index < total {
            let chunk = MCPRemoteShell.key(id: id, verb: "chunk", index: index)
            switch await waitForShell([chunk, result], timeout: index == 0 ? 90 : 60) {
            case let .received(key, payload) where key == result:
                let failure = Self.commandText(payload)
                return failure.isError ? failure : .error("The remote script ended before sending the file.")
            case let .received(_, payload):
                guard let bar = payload.firstIndex(of: "|"), let count = Int(payload[..<bar]), count > 0 else {
                    return .error("A damaged part arrived. Try again.")
                }
                total = count
                encoded += payload[payload.index(after: bar)...]
            case let .stopped(reason): return .error(reason)
            case .timedOut:
                return .error(index == 0
                    ? "The remote script did not start or the file is still being read. Take a screenshot and try again."
                    : "The remote computer stopped sending after part \(index) of \(total).")
            }
            do { try await model.tools.sendAgentClipboard("MVR-\(id)|next|\(index)") }
            catch { return .error("The transfer could not be acknowledged over the shared clipboard.") }
            index += 1
        }
        let data: Data
        do { data = try MCPRemoteShell.decode(encoded) } catch { return .error("The received file was damaged. Try again.") }
        // The bytes come from the remote computer, so they only ever land as a
        // new file in one folder: never a path the agent chooses, never overwriting.
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacViewer AI", isDirectory: true)
        let destination = ReceivedFilesFolder.uniqueURL(for: MCPRemoteShell.fileName(ofRemotePath: remotePath), in: folder)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch { return .error("The file could not be saved to \(destination.path).") }
        _ = await waitForShell([result], timeout: 5)
        return .text("Saved \(data.count) bytes to \(destination.path) on this Mac.")
    }

    private enum ShellWait {
        case received(key: String, payload: String)
        case timedOut
        case stopped(String)
    }

    private func waitForShell(_ keys: [String], timeout: Double) async -> ShellWait {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for key in keys {
                if let payload = shellInbox.removeValue(forKey: key) { return .received(key: key, payload: payload) }
            }
            if isStoppedForSession { return .stopped(MCPToolGate.stoppedForSession) }
            guard model.phase == .connected else { return .stopped("The remote session ended.") }
            try? await Task.sleep(seconds: 0.1)
        }
        return .timedOut
    }

    private func consumeShellText(_ text: String) -> Bool {
        guard MCPRemoteShell.isChannelText(text) else { return false }
        if let message = MCPRemoteShell.Message(parsing: text),
           shellChannels.contains(message.id) || consoleChannels.contains(message.id),
           message.verb == "res" || message.verb == "ack" || message.verb == "chunk" {
            shellInbox[message.key] = message.payload
            heardFrom.insert(message.id)
            if message.verb == "res" {
                finished.insert(message.id)
                if let sid = commandWindow.removeValue(forKey: message.id) { consoleBusy[sid] = nil }
            }
        }
        return true
    }

    /// Runs `script` in this computer's visible support window, opening one
    /// first when needed. Returns a user-facing error, or nil once the window
    /// picked the command up (or, for `admin`, once the elevated run started
    /// in the background: its result arrives under `id` for command_result).
    private func launch(id: String, script: String, admin: Bool, note: String) async -> String? {
        if let error = await prepareChannel() { return error }
        register(id)
        if admin {
            Task { [weak self] in
                guard let self, let error = await self.runElevated(id: id, script: script, note: note) else { return }
                self.shellInbox[MCPRemoteShell.key(id: id, verb: "res", index: nil)] = "EXIT=1\n" + error
            }
            return nil
        }
        return await runInConsole(id: id, script: script, note: note)
    }

    private func prepareChannel() async -> String? {
        if let refusal = inputRefusal() { return refusal }
        let tools = model.tools
        tools.agentClipboardFilter = { [weak self] text in self?.consumeShellText(text) ?? false }
        if !tools.clipboardEnabled {
            tools.setClipboardEnabled(true)
            for _ in 0..<100 {
                try? await Task.sleep(seconds: 0.1)
                if tools.clipboardEnabled || !tools.isUpdatingClipboard { break }
            }
            guard tools.clipboardEnabled else {
                return "Clipboard sharing could not be turned on. Ask the user to turn it on in the session toolbar."
            }
            record(client: "MacViewer", tool: "clipboard", detail: "Turned on clipboard sharing for AI commands.", isError: false)
        }
        return nil
    }

    private func register(_ id: String) {
        shellChannels.append(id)
        if shellChannels.count > 50 {
            let dropped = Set(shellChannels.prefix(shellChannels.count - 50))
            shellChannels.removeFirst(shellChannels.count - 50)
            shellInbox = shellInbox.filter { entry in !dropped.contains { entry.key.hasPrefix($0 + "|") } }
            heardFrom.subtract(dropped)
            finished.subtract(dropped)
        }
    }

    private func runInConsole(id: String, script: String, note: String) async -> String? {
        let key = ObjectIdentifier(model)
        for _ in 0..<2 {
            let sid: String
            if let open = consoles[key]?.normal {
                sid = open
            } else {
                switch await openConsole() {
                case let .success(new): sid = new
                case let .failure(error): return error.message
                }
            }
            switch await dispatch(id: id, sid: sid, note: note, script: script) {
            case .picked: return nil
            case let .failed(error): return error
            case .notPicked: consoles[key]?.normal = nil // The window was closed: open a new one.
            }
        }
        return "The PowerShell support window did not take the command. Take a screenshot to see what has focus."
    }

    /// Opens the visible support window: Win+R → `powershell`, then starts the
    /// loop in it. Waits until the loop reports ready.
    private func openConsole() async -> Result<String, ShellFailure> {
        let sid = MCPRemoteShell.newID()
        consoleChannels.insert(sid)
        do { try await model.tools.sendAgentClipboard(MCPRemoteShell.consoleScript(sid: sid, admin: false)) }
        catch { return .failure(ShellFailure("The support script could not be sent over the shared clipboard.")) }
        try? await Task.sleep(seconds: 0.7)
        sendKeys("win+r")
        try? await Task.sleep(seconds: 1.2)
        sendKeys("ctrl+a")
        typeText(MCPRemoteShell.consoleCommand)
        try? await Task.sleep(seconds: 0.3)
        sendKeys("enter")
        markActing()
        // A new console buffers what is typed until its prompt is ready.
        try? await Task.sleep(seconds: 2.5)
        typeText(MCPRemoteShell.bootLine(sid: sid))
        try? await Task.sleep(seconds: 0.3)
        sendKeys("enter")
        switch await waitForShell([MCPRemoteShell.key(id: sid, verb: "ack", index: -9)], timeout: 30) {
        case .received:
            consoles[ObjectIdentifier(model), default: ConsoleWindows()].normal = sid
            return .success(sid)
        case let .stopped(reason): return .failure(ShellFailure(reason))
        case .timedOut:
            return .failure(ShellFailure("The PowerShell support window did not start. Take a screenshot: the Run box or " +
                                         "the window may not have opened, or another window took the keyboard."))
        }
    }

    private enum Pickup { case picked, notPicked, failed(String) }

    /// Hands one command to support window `sid` and waits until it is picked up.
    private func dispatch(id: String, sid: String, note: String, script: String) async -> Pickup {
        if let running = consoleBusy[sid] {
            return .failed("Command \(running) is still running in the support window. Wait for it with command_result, " +
                           "or ask the person to close that window, then try again.")
        }
        do { try await model.tools.sendAgentClipboard(MCPRemoteShell.command(id: id, sid: sid, note: note, script: script)) }
        catch { return .failed("The script could not be sent over the shared clipboard.") }
        // Any reply for this id means the window took it: a fast script can
        // overwrite the pickup signal on the clipboard before this Mac sees it.
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if heardFrom.contains(id) {
                if !finished.contains(id) {
                    consoleBusy[sid] = id
                    commandWindow[id] = sid
                }
                markActing()
                return .picked
            }
            if isStoppedForSession { return .failed(MCPToolGate.stoppedForSession) }
            guard model.phase == .connected else { return .failed("The remote session ended.") }
            try? await Task.sleep(seconds: 0.1)
        }
        return .notPicked
    }

    /// Admin commands run in a second, elevated support window, opened from the
    /// normal one with Start-Process -Verb RunAs (Windows asks with UAC).
    private func runElevated(id: String, script: String, note: String) async -> String? {
        let key = ObjectIdentifier(model)
        if let sid = consoles[key]?.admin {
            switch await dispatch(id: id, sid: sid, note: note, script: script) {
            case .picked: return nil
            case let .failed(error): return error
            case .notPicked: consoles[key]?.admin = nil
            }
        }
        let adminSid = MCPRemoteShell.newID()
        consoleChannels.insert(adminSid)
        let elevate = MCPRemoteShell.newID()
        register(elevate)
        if let error = await runInConsole(id: elevate, script: MCPRemoteShell.elevateScript(adminSid: adminSid),
                                          note: "Mở cửa sổ quản trị: Windows sẽ hỏi, bấm Có / Opening an administrator window: click Yes") {
            return error
        }
        switch await waitForShell([MCPRemoteShell.key(id: adminSid, verb: "ack", index: -9)], timeout: 180) {
        case .received: consoles[key, default: ConsoleWindows()].admin = adminSid
        case let .stopped(reason): return reason
        case .timedOut: return "The administrator PowerShell window did not open: the UAC prompt was declined or not answered."
        }
        switch await dispatch(id: id, sid: adminSid, note: note, script: script) {
        case .picked: return nil
        case let .failed(error): return error
        case .notPicked: return "The administrator support window did not take the command. Take a screenshot."
        }
    }

    private func typeText(_ text: String) {
        for event in MCPKeys.typingPlan(for: text).events { model.sendAgentInput(event) }
    }

    private func sendKeys(_ keys: String) {
        guard let chords = try? MCPKeys.parse(keys) else { return }
        for chord in chords { for event in MCPKeys.events(for: chord) { model.sendAgentInput(event) } }
    }

    private func markActing() {
        isActing = true
        actingTask?.cancel()
        actingTask = Task { [weak self] in
            try? await Task.sleep(seconds: 8)
            guard !Task.isCancelled else { return }
            self?.isActing = false
        }
    }

    /// Path of the stdio helper that MCP clients launch.
    static var helperURL: URL {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("macviewer-mcp")
    }
}

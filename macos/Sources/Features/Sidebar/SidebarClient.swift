import Foundation

/// Omnity: network side of the right-side panel. Tasks and the calendar come from the omni-tasks server
/// over the tailnet (the same one Tally uses; the tailnet login admits the Mac), the unit context from
/// `omni-unit-context` on the switcher host, over the switcher's ssh connection.

enum SidebarClient {
    static var baseURL: URL {
        let env = ProcessInfo.processInfo.environment["OMNITY_SIDEBAR_TASKS_URL"]
        return URL(string: env ?? "https://omni.tiffany-ling.ts.net:8443")!
    }

    static var unitContextCommand: String {
        ProcessInfo.processInfo.environment["OMNITY_UNIT_CONTEXT_COMMAND"] ?? "/home/robot/.local/bin/omni-unit-context"
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    struct Failure: Error { var status: Int }

    static func call<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                   body: [String: Any]? = nil, as: T.Type = T.self) async throws -> T {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Omnity", forHTTPHeaderField: "X-Omni-Device")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure(status: status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct CompleteResponse: Decodable { var task: SBTask? }
    struct TaskResponse: Decodable { var task: SBTask? }

    static func tasks(since: Int) async throws -> SBTasksResponse {
        try await call("GET", "tasks", query: ["since": String(since)])
    }
    static func units() async throws -> [SBUnit] {
        try await call("GET", "units", as: SBUnitsResponse.self).units
    }
    static func events(day: String) async throws -> [SBEvent] {
        try await call("GET", "events", query: ["from": day, "to": day], as: SBEventsResponse.self).events
    }
    static func complete(_ t: SBTask) async throws -> CompleteResponse {
        try await call("POST", "tasks/\(t.id)/complete", body: ["baseRev": t.rev])
    }
    static func setSubtask(_ t: SBTask, _ s: SBSub, done: Bool) async throws -> SBTask? {
        try await call("PATCH", "tasks/\(t.id)/subtasks/\(s.index)", body: ["was": s.text, "done": done], as: TaskResponse.self).task
    }
    static func addNote(_ id: String, _ text: String) async throws {
        _ = try await call("POST", "tasks/\(id)/history", body: ["text": text], as: TaskResponse.self)
    }
    /// Undo of a completion: a repeating task goes back to its date, a one-off task is created again.
    static func reopen(_ original: SBTask, next: SBTask?) async throws {
        if let next {
            let due: Any = original.due ?? NSNull()
            _ = try await call("PATCH", "tasks/\(next.id)", body: ["baseRev": next.rev, "due": due], as: TaskResponse.self)
        } else {
            var b: [String: Any] = ["unit": original.unit, "title": original.title]
            if let g = original.group { b["group"] = g }
            if !original.notes.isEmpty { b["notes"] = original.notes }
            if let d = original.due { b["due"] = d }
            if let r = original.repeatRule { b["repeat"] = r }
            _ = try await call("POST", "tasks", body: b, as: TaskResponse.self)
        }
    }

    static func unitContext(host: String, unit: String) async -> SBUnitContext? {
        guard unit.range(of: #"^[a-z0-9-]{1,60}$"#, options: .regularExpression) != nil,
              let r = await TmuxSwitchClient.execute(host: host, ["--json", unit], command: unitContextCommand),
              r.status == 0 else { return nil }
        return try? JSONDecoder().decode(SBUnitContext.self, from: r.out)
    }
}

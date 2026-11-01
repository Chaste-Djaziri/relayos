// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/NativeMCPHTTP.swift
import Foundation
import Network
import MCP

/// Experimental in-process MCP transport with localhost OAuth and locally
/// approved native mutations. Full Streamable HTTP/SSE interoperability and
/// public deployment review are still required.
struct NativeMCPHTTP {
    struct Reply {
        let status: Int
        let body: Data
        let contentType: String
        let extraHeaders: [String: String]
        init(_ status: Int, _ object: Any, contentType: String = "application/json") {
            self.status = status
            self.extraHeaders = [:]
            self.body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            self.contentType = contentType
        }
        init(status: Int, raw: String, contentType: String, headers: [String: String] = [:]) {
            self.status = status
            self.body = Data(raw.utf8)
            self.contentType = contentType
            self.extraHeaders = headers
        }
    }

    let authorization: NativeMCPAuthorization
    let port: UInt16
    let actions: NativeMCPActions?
    let oauth: NativeMCPOAuth?

    init(authorization: NativeMCPAuthorization, port: UInt16, actions: NativeMCPActions? = nil,
         oauth: NativeMCPOAuth? = nil) {
        self.authorization = authorization
        self.port = port
        self.actions = actions
        self.oauth = oauth
    }

    private func response(_ id: Any, _ result: Any) -> Reply {
        Reply(200, ["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func failure(_ id: Any, _ code: Int, _ message: String) -> Reply {
        Reply(200, ["jsonrpc": "2.0", "id": id,
                    "error": ["code": code, "message": message]])
    }

    private func toolText(_ id: Any, _ value: Any) -> Reply {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return response(id, ["content": [["type": "text", "text": text]], "isError": false])
    }

    private func oauthResponse(method: String, path: String, body: Data) -> Reply? {
        guard let oauth,
              let components = URLComponents(string: "http://localhost" + path) else { return nil }
        let route = components.path
        let params = Dictionary((components.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        }, uniquingKeysWith: { first, _ in first })
        do {
            if method == "GET" && route == "/.well-known/oauth-authorization-server" {
                return Reply(200, oauth.metadata())
            }
            if method == "GET" && route == "/.well-known/oauth-protected-resource/mcp" {
                return Reply(200, ["resource": oauth.store.endpoint,
                                   "authorization_servers": [oauth.issuer],
                                   "scopes_supported": ["mcp"]])
            }
            if method == "POST" && route == "/register" {
                guard let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                else { return Reply(400, ["error": "invalid_client_metadata"]) }
                return Reply(201, try oauth.register(payload))
            }
            if method == "GET" && route == "/authorize" {
                let id = try oauth.authorize(params)
                return Reply(status: 302, raw: "", contentType: "text/plain",
                             headers: ["Location": "/oauth/approval/" + id])
            }
            if method == "GET" && route.hasPrefix("/oauth/approval/") {
                let id = String(route.dropFirst("/oauth/approval/".count))
                switch try oauth.approvalStatus(id) {
                case .pending:
                    return Reply(status: 200, raw: """
                        <!doctype html><html><head><meta http-equiv="refresh" content="2"></head>
                        <body><h2>RelayOS authorization pending</h2>
                        <p>Approve or deny this connection in the local RelayOS window.</p></body></html>
                        """, contentType: "text/html; charset=utf-8")
                case .denied:
                    return Reply(status: 403, raw: "Authorization denied or expired.",
                                 contentType: "text/plain")
                case .redirect(let url):
                    return Reply(status: 302, raw: "", contentType: "text/plain",
                                 headers: ["Location": url.absoluteString])
                }
            }
            if method == "POST" && (route == "/token" || route == "/revoke") {
                guard let data = String(data: body, encoding: .utf8),
                      data.utf8.count < 16_384 else {
                    return Reply(400, ["error": "invalid_request"])
                }
                let forms = URLComponents(string: "http://localhost/?" + data
                    .replacingOccurrences(of: "+", with: "%20"))?.queryItems ?? []
                let arguments = Dictionary(forms.compactMap { item -> (String, String)? in
                    guard let value = item.value else { return nil }
                    return (item.name, value)
                }, uniquingKeysWith: { first, _ in first })
                if route == "/token" { return Reply(200, try oauth.token(arguments)) }
                guard let token = arguments["token"], let client = arguments["client_id"] else {
                    return Reply(400, ["error": "invalid_request"])
                }
                try oauth.revoke(token: token, clientID: client)
                return Reply(200, [:])
            }
        } catch {
            return Reply(400, ["error": "invalid_request",
                               "error_description": "Invalid or expired authorization request"])
        }
        return nil
    }

    func handle(method: String, path: String, headers: [String: String],
                body: Data) -> Reply {
        // No browser-controlled Origin can access this local API.
        if headers["origin"] != nil {
            return Reply(403, ["error": "Cross-origin requests are not accepted"])
        }
        guard let host = headers["host"]?.lowercased(),
              [ "127.0.0.1:\(port)", "localhost:\(port)" ].contains(host)
        else { return Reply(400, ["error": "Invalid host"]) }
        if method == "GET" && path == "/health" {
            return Reply(200, ["status": "native-experimental", "production": false])
        }
        if let authorizationResponse = oauthResponse(method: method, path: path, body: body) {
            return authorizationResponse
        }
        guard path == "/mcp" else { return Reply(404, ["error": "Not found"]) }
        guard method == "POST" else { return Reply(405, ["error": "Method not allowed"]) }
        guard let bearer = headers["authorization"], bearer.hasPrefix("Bearer "),
              authorization.validateAccessToken(
                String(bearer.dropFirst(7)),
                resource: "http://127.0.0.1:\(port)/mcp")
        else { return Reply(401, ["error": "Unauthorized"]) }
        guard body.count <= 32768,
              let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              request["jsonrpc"] as? String == "2.0",
              let name = request["method"] as? String
        else { return Reply(400, ["error": "Malformed JSON-RPC request"]) }
        // Notifications do not have an id. They do not create a response.
        let id: Any = request["id"] ?? NSNull()
        if request["id"] == nil {
            return Reply(202, ["status": "notification accepted"])
        }
        switch name {
        case "initialize":
            return response(id, [
                "protocolVersion": Version.latest,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "RelayOS Native (experimental)",
                               "version": "0.1.0"]
            ])
        case "ping":
            return response(id, [:])
        case "tools/list":
            let sessionSchema: [String: Any] = [
                "type": "object",
                "properties": [
                    "session_id": ["type": "string"],
                    "project_root": ["type": "string"],
                    "path": ["type": "string"]
                ],
                "required": ["session_id", "project_root", "path"]
            ]
            let actionSchema: [String: Any] = [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": [
                        "write_project_file", "apply_project_patch", "run_project_command",
                        "start_project_command_job", "screen_snapshot", "show_guidance",
                        "start_guidance_session"
                    ]],
                    "arguments": ["type": "object"]
                ],
                "required": ["kind", "arguments"]
            ]
            let executionSchema: [String: Any] = [
                "type": "object",
                "properties": [
                    "kind": ["type": "string"],
                    "arguments": ["type": "object"],
                    "request_id": ["type": "string"]
                ],
                "required": ["kind", "arguments", "request_id"]
            ]
            let jobSchema: [String: Any] = [
                "type": "object",
                "properties": [
                    "session_id": ["type": "string"],
                    "project_root": ["type": "string"],
                    "job_id": ["type": "string"]
                ],
                "required": ["session_id", "project_root", "job_id"]
            ]
            let guidanceSchema: [String: Any] = [
                "type": "object",
                "properties": [
                    "session_id": ["type": "string"],
                    "project_root": ["type": "string"],
                    "guidance_session_id": ["type": "string"]
                ],
                "required": ["session_id", "project_root", "guidance_session_id"]
            ]
            return response(id, ["tools": [
                ["name": "system_status",
                 "description": "Read the native Mac's hostname, OS and available system measurements.",
                 "inputSchema": ["type": "object", "properties": [:]]],
                ["name": "list_processes",
                 "description": "List running Mac processes by CPU or memory usage (read-only).",
                 "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "minimum": 1, "maximum": 200],
                        "sort_by": ["type": "string", "enum": ["cpu", "memory"]]
                    ]
                 ]],
                ["name": "list_project_files",
                 "description": "List files only under a previously locally approved project session.",
                 "inputSchema": sessionSchema],
                ["name": "read_project_file",
                 "description": "Read UTF-8 files only under a previously locally approved project session.",
                 "inputSchema": sessionSchema],
                ["name": "propose_native_action", "inputSchema": actionSchema,
                 "description": "Request local approval for an exact file or command operation."],
                ["name": "execute_native_action", "inputSchema": executionSchema,
                 "description": "Run the exact action approved in the native window."],
                ["name": "read_project_command_job", "inputSchema": jobSchema,
                 "description": "Read output for an owned native terminal job."],
                ["name": "cancel_project_command_job", "inputSchema": jobSchema,
                 "description": "Cancel an owned native terminal job."],
                ["name": "clear_guidance", "inputSchema": ["type": "object"],
                 "description": "Remove guidance overlays created by the Swift app."],
                ["name": "guidance_session_status", "inputSchema": guidanceSchema,
                 "description": "Read an approved, time-limited native guidance session."],
                ["name": "refresh_guidance_screen", "inputSchema": guidanceSchema,
                 "description": "Capture the screen during an active, locally approved guidance session."],
                ["name": "stop_guidance_session", "inputSchema": guidanceSchema,
                 "description": "Stop an active, locally approved guidance session."]
            ]])
        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            let tool = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            if tool == "system_status" {
                return toolText(id, NativeMCPSystem().status())
            }
            if tool == "list_processes" {
                let limit = arguments["limit"] as? Int ?? 50
                let sorting = arguments["sort_by"] as? String ?? "cpu"
                do {
                    return toolText(id, try NativeMCPSystem().listProcesses(
                        limit: limit, sortBy: sorting))
                } catch {
                    return failure(id, -32602, "Invalid process listing parameters")
                }
            }
            if tool == "list_project_files" || tool == "read_project_file" {
                guard let session = arguments["session_id"] as? String,
                      let root = arguments["project_root"] as? String,
                      let path = arguments["path"] as? String else {
                    return failure(id, -32602, "Missing session_id, project_root, or path")
                }
                let project = NativeMCPProjectFiles(authorization: authorization)
                do {
                    if tool == "list_project_files" {
                        let files = try project.list(sessionID: session, projectRoot: root, folder: path)
                        return toolText(id, files)
                    }
                    let content = try project.read(sessionID: session, projectRoot: root, path: path)
                    return response(id, ["content": [["type": "text", "text": content]],
                                         "isError": false])
                } catch {
                    return failure(id, -32003, "Denied, out of scope, unavailable, or oversized file")
                }
            }
            if let actions {
                do {
                    switch tool {
                    case "propose_native_action":
                        guard let kind = arguments["kind"] as? String,
                              let args = arguments["arguments"] as? [String: Any] else {
                            return failure(id, -32602, "Missing kind or arguments")
                        }
                        return toolText(id, try actions.propose(kind: kind, args: args))
                    case "execute_native_action":
                        guard let kind = arguments["kind"] as? String,
                              let args = arguments["arguments"] as? [String: Any],
                              let requestID = arguments["request_id"] as? String else {
                            return failure(id, -32602, "Missing request data")
                        }
                        return toolText(id, try actions.execute(kind: kind, args: args, requestID: requestID))
                    case "read_project_command_job":
                        return toolText(id, try actions.readJob(arguments))
                    case "cancel_project_command_job":
                        return toolText(id, try actions.cancelJob(arguments))
                    case "clear_guidance":
                        return toolText(id, actions.clearGuidance())
                    case "guidance_session_status":
                        return toolText(id, try actions.guidanceStatus(arguments))
                    case "refresh_guidance_screen":
                        return toolText(id, try actions.guidanceCapture(arguments))
                    case "stop_guidance_session":
                        return toolText(id, try actions.guidanceStop(arguments))
                    default: break
                    }
                } catch {
                    return failure(id, -32003, "Operation denied or invalid")
                }
            }
            return failure(id, -32601, "Unimplemented tool")
        default:
            return failure(id, -32601, "Unknown method")
        }
    }
}

/// Bind a dedicated loopback-only port; never compete with production :8765.
/// No subprocess is spawned. No external interface is exposed.
final class NativeMCPListener {
    private let queue = DispatchQueue(label: "pro.micorp.relayos.native-mcp", qos: .utility)
    private let handler: NativeMCPHTTP
    private let jobs: NativeMCPJobs?
    private var listener: NWListener?

    init(port: UInt16 = 18765,
         authorization: NativeMCPAuthorization = NativeMCPAuthorization(),
         approvalStore: NativeMCPApprovalStore? = nil,
         oauth: NativeMCPOAuth? = nil) {
        let actions = approvalStore.map { NativeMCPActions(authorization: authorization, approvals: $0) }
        self.handler = NativeMCPHTTP(authorization: authorization, port: port, actions: actions, oauth: oauth)
        self.jobs = actions?.jobs
    }

    func start() throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: handler.port), handler.port > 1024 else {
            throw NativeError.invalidPort
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let newListener = try NWListener(using: parameters)
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.start(queue: queue)
        listener = newListener
    }

    func stop() {
        jobs?.shutdown()
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] content, _, finished, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            if let content { bytes.append(content) }
            guard bytes.count <= 65536 else {
                self.send(NativeMCPHTTP.Reply(413, ["error": "Request too large"]), to: connection)
                return
            }
            let delimiter = Data("\r\n\r\n".utf8)
            if let endOfHeaders = bytes.range(of: delimiter) {
                let headerData = bytes.subdata(in: 0..<endOfHeaders.lowerBound)
                guard let text = String(data: headerData, encoding: .utf8) else {
                    self.send(NativeMCPHTTP.Reply(400, ["error": "Bad headers"]), to: connection)
                    return
                }
                let lines = text.components(separatedBy: "\r\n")
                let first = lines.first?.split(separator: " ").map(String.init) ?? []
                guard first.count == 3, first[2].hasPrefix("HTTP/1."),
                      first[1].hasPrefix("/"), !first[1].contains("#"), first[1].utf8.count < 8192
                else {
                    self.send(NativeMCPHTTP.Reply(400, ["error": "Bad request"]), to: connection)
                    return
                }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else {
                        self.send(NativeMCPHTTP.Reply(400, ["error": "Malformed header"]), to: connection)
                        return
                    }
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    guard headers[key] == nil else {
                        self.send(NativeMCPHTTP.Reply(400, ["error": "Duplicate header"]), to: connection)
                        return
                    }
                    headers[key] = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                }
                let size = Int(headers["content-length"] ?? "0") ?? -1
                guard size >= 0 && size <= 32768,
                      headers["transfer-encoding"] == nil else {
                    self.send(NativeMCPHTTP.Reply(413, ["error": "Unsupported payload"]), to: connection)
                    return
                }
                let bodyOffset = endOfHeaders.upperBound
                if bytes.count - bodyOffset >= size {
                    let body = bytes.subdata(in: bodyOffset..<(bodyOffset + size))
                    self.send(self.handler.handle(method: first[0], path: first[1],
                                                  headers: headers, body: body),
                              to: connection)
                    return
                }
            }
            if error == nil && !finished {
                self.receive(connection, accumulated: bytes)
            } else {
                connection.cancel()
            }
        }
    }

    private func send(_ reply: NativeMCPHTTP.Reply, to connection: NWConnection) {
        let reason: String
        switch reply.status {
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 302: reason = "Found"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        default: reason = "Error"
        }
        let header = "HTTP/1.1 \(reply.status) \(reason)\r\nContent-Type: \(reply.contentType)\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var output = Data((header.replacingOccurrences(of: "\r\n\r\n", with: "\r\n" + reply.extraHeaders.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n")).utf8)
        output.append(reply.body)
        connection.send(content: output, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    enum NativeError: Error { case invalidPort }
}

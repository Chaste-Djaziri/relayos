// Path: Native/LaptopBridgeApp/Sources/LaptopBridgeApp/Services/NativeMCPHTTP.swift
import Foundation
import Network
import MCP

/// Experimental, read-only in-process MCP transport.
/// It is NOT production-compatible until OAuth registration, authorization and
/// every currently exported Python tool are ported and parity-tested.
struct NativeMCPHTTP {
    struct Reply {
        let status: Int
        let body: Data
        let contentType: String
        init(_ status: Int, _ object: Any, contentType: String = "application/json") {
            self.status = status
            self.body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            self.contentType = contentType
        }
    }

    let authorization: NativeMCPAuthorization
    let port: UInt16

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
                 "inputSchema": sessionSchema]
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
            // Never execute a command, create a grant, or mutate a file here.
            return failure(id, -32601, "Tool is unavailable in native experimental mode")
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
    private var listener: NWListener?

    init(port: UInt16 = 18765,
         authorization: NativeMCPAuthorization = NativeMCPAuthorization()) {
        self.handler = NativeMCPHTTP(authorization: authorization, port: port)
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
                      first[1].hasPrefix("/"), !first[1].contains("?")
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
        var output = Data(header.utf8)
        output.append(reply.body)
        connection.send(content: output, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    enum NativeError: Error { case invalidPort }
}

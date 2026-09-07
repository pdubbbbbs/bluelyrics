// Minimal HTTP/1.1 server on Network.framework: static routes, JSON, and
// Server-Sent Events. Enough for the lyrics page and its LAN cast clients.

import Foundation
import Network

struct HTTPRequest {
  let method: String
  let path: String
  let query: [String: String]
  let headers: [String: String]
  let body: Data
}

struct HTTPResponse {
  var status = 200
  var contentType = "text/plain; charset=utf-8"
  var body = Data()
  var extraHeaders: [String: String] = [:]

  static func text(_ s: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(status: status, body: Data(s.utf8))
  }
  static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    return HTTPResponse(status: status, contentType: "application/json", body: data)
  }
  static func file(_ data: Data, type: String) -> HTTPResponse {
    HTTPResponse(status: 200, contentType: type, body: data)
  }
  static let notFound = HTTPResponse.text("not found", status: 404)
}

/// A live SSE client. `send` writes one event; returns false once the peer is gone.
final class SSEClient {
  let connection: NWConnection
  private(set) var alive = true
  init(connection: NWConnection) { self.connection = connection }
  func send(event: String, data: Any) {
    guard alive, let json = try? JSONSerialization.data(withJSONObject: data) else { return }
    var frame = Data("event: \(event)\ndata: ".utf8)
    frame.append(json)
    frame.append(Data("\n\n".utf8))
    connection.send(content: frame, completion: .contentProcessed { [weak self] error in
      if error != nil { self?.alive = false }
    })
  }
  func close() { alive = false; connection.cancel() }
}

final class HTTPServer {
  typealias Handler = (HTTPRequest) -> HTTPResponse
  private var listener: NWListener?
  private let queue = DispatchQueue(label: "bluelyrics.http", attributes: .concurrent)
  private var routes: [(method: String, path: String, prefix: Bool, handler: Handler)] = []
  private var sseHandler: ((HTTPRequest, SSEClient) -> Void)?
  private var ssePath = "/events"
  let port: UInt16
  var onFailure: (() -> Void)?

  init(port: UInt16) { self.port = port }

  func route(_ method: String, _ path: String, prefix: Bool = false, _ handler: @escaping Handler) {
    routes.append((method, path, prefix, handler))
  }
  func sse(_ path: String, _ handler: @escaping (HTTPRequest, SSEClient) -> Void) {
    ssePath = path; sseHandler = handler
  }

  func start() throws {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready: Log.info("HTTP listener ready on port \(listener.port?.rawValue ?? 0)")
      case .failed(let error): Log.info("HTTP listener failed: \(error)"); listener.cancel(); self.onFailure?()
      case .waiting(let error): Log.info("HTTP listener waiting: \(error)")
      case .cancelled: Log.info("HTTP listener cancelled")
      default: break
      }
    }
    listener.start(queue: queue)
    self.listener = listener
  }

  func stop() { listener?.cancel() }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    readRequest(connection, buffer: Data())
  }

  private func readRequest(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      if error != nil { connection.cancel(); return }
      if let request = self.parse(buffer) {
        self.dispatch(request, on: connection)
      } else if isComplete || buffer.count > 1_000_000 {
        connection.cancel()
      } else {
        self.readRequest(connection, buffer: buffer)
      }
    }
  }

  /// Returns a request once headers and the declared body have fully arrived.
  private func parse(_ buffer: Data) -> HTTPRequest? {
    guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines {
      if let colon = line.firstIndex(of: ":") {
        headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      }
    }
    let length = Int(headers["content-length"] ?? "0") ?? 0
    let bodyStart = headerEnd.upperBound
    guard buffer.count - bodyStart >= length else { return nil }
    let body = buffer[bodyStart..<(bodyStart + length)]
    let target = String(requestLine[1])
    let parts = target.split(separator: "?", maxSplits: 1)
    var query: [String: String] = [:]
    if parts.count == 2 {
      for pair in parts[1].split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
        let value = kv.count == 2 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
        query[key] = value
      }
    }
    return HTTPRequest(method: String(requestLine[0]), path: String(parts[0]).removingPercentEncoding ?? String(parts[0]),
                       query: query, headers: headers, body: Data(body))
  }

  private func dispatch(_ request: HTTPRequest, on connection: NWConnection) {
    if request.method == "OPTIONS" {
      write(HTTPResponse(status: 204), to: connection); return
    }
    if request.method == "GET", request.path == ssePath, let sseHandler {
      let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n"
      connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
      sseHandler(request, SSEClient(connection: connection))
      return
    }
    for route in routes where route.method == request.method {
      if route.prefix ? request.path.hasPrefix(route.path) : request.path == route.path {
        write(route.handler(request), to: connection); return
      }
    }
    write(.notFound, to: connection)
  }

  private func write(_ response: HTTPResponse, to connection: NWConnection) {
    var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
    head += "Content-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\n"
    head += "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n"
    head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n"
    for (k, v) in response.extraHeaders { head += "\(k): \(v)\r\n" }
    head += "\r\n"
    var payload = Data(head.utf8); payload.append(response.body)
    connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
  }

  private func reason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"; case 204: return "No Content"; case 400: return "Bad Request"
    case 404: return "Not Found"; case 413: return "Payload Too Large"; default: return "OK"
    }
  }
}

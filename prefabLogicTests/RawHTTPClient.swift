//
//  RawHTTPClient.swift
//  prefabLogicTests — a small Darwin-socket HTTP client for the F-1 transport tests (PRD-1-01 plan R7-6 / R7-11).
//  It sends raw bytes (so a test controls `Connection:` and the HTTP version exactly) and reads until the server
//  closes the connection, a stop condition holds, or a timeout (3 s by default) passes.
//

import Foundation
import Darwin

struct RawExchange {
    /// Every byte received.
    var bytes: [UInt8]
    /// The server closed (EOF) or reset the connection while we were reading.
    var closedByServer: Bool
    /// The read ended with ECONNRESET.
    var reset: Bool
    /// Non-nil when connect() failed (the errno).
    var connectErrno: Int32?
}

struct ParsedResponse {
    var version: String
    var status: Int
    var headers: [String: String]      // lower-cased names
    var body: [UInt8]
    var bodyString: String { String(decoding: body, as: UTF8.self) }
}

enum RawHTTPClient {
    /// Connects to host:port and returns the socket, or the errno of a failed connect.
    private static func connect(host: String, port: Int) -> (fd: Int32, errno: Int32?) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (-1, errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        _ = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 { let e = errno; close(fd); return (-1, e) }
        return (fd, nil)
    }

    /// 0 when a TCP connect to host:port succeeds, else the errno (ECONNREFUSED when nothing listens there).
    static func connectErrno(host: String, port: Int) -> Int32 {
        let c = connect(host: host, port: port)
        if c.fd >= 0 { close(c.fd); return 0 }
        return c.errno ?? -1
    }

    /// Sends `request` as raw bytes and reads. Reading stops when the server closes, when `timeout` passes, or —
    /// if `stopWhen` is given — `linger` seconds after `stopWhen(bytes)` first holds (to see whether the server then closes).
    static func exchange(host: String = "127.0.0.1", port: Int, request: String, timeout: TimeInterval = 3.0,
                         stopWhen: (([UInt8]) -> Bool)? = nil, linger: TimeInterval = 0.3) -> RawExchange {
        let c = connect(host: host, port: port)
        guard c.fd >= 0 else { return RawExchange(bytes: [], closedByServer: false, reset: false, connectErrno: c.errno) }
        let fd = c.fd
        defer { close(fd) }
        let out = Array(request.utf8)
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { send(fd, $0.baseAddress! + sent, out.count - sent, 0) }
            if n <= 0 { break }
            sent += n
        }
        var bytes: [UInt8] = []
        var closed = false, reset = false
        var deadline = Date().addingTimeInterval(timeout)
        var stopSeen = false
        var chunk = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            let pr = poll(&pfd, 1, ms)
            if pr > 0 {
                let n = recv(fd, &chunk, chunk.count, 0)
                if n > 0 {
                    bytes.append(contentsOf: chunk[0..<n])
                } else if n == 0 {
                    closed = true; break
                } else if errno == ECONNRESET {
                    closed = true; reset = true; break
                } else if errno != EINTR && errno != EAGAIN {
                    break
                }
            }
            if !stopSeen, let stop = stopWhen, stop(bytes) {
                stopSeen = true
                deadline = min(deadline, Date().addingTimeInterval(linger))
            }
        }
        return RawExchange(bytes: bytes, closedByServer: closed, reset: reset, connectErrno: nil)
    }

    /// Parses consecutive complete HTTP/1.x responses (each must carry Content-Length). Trailing partial data is ignored.
    static func parseResponses(_ bytes: [UInt8]) -> [ParsedResponse] {
        var out: [ParsedResponse] = []
        var i = 0
        let sep: [UInt8] = [13, 10, 13, 10]
        while i < bytes.count {
            guard let headEnd = find(sep, in: bytes, from: i) else { break }
            let head = String(decoding: bytes[i..<headEnd], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let statusLine = lines.removeFirst()
            let parts = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2, let status = Int(parts[1]) else { break }
            var headers: [String: String] = [:]
            for l in lines {
                guard let colon = l.firstIndex(of: ":") else { continue }
                headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let len = headers["content-length"].flatMap({ Int($0) }) else { break }
            let bodyStart = headEnd + sep.count
            guard bodyStart + len <= bytes.count else { break }
            out.append(ParsedResponse(version: parts[0], status: status, headers: headers, body: Array(bytes[bodyStart..<(bodyStart + len)])))
            i = bodyStart + len
        }
        return out
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        var k = from
        while k <= hay.count - needle.count {
            if hay[k] == needle[0] && Array(hay[k..<(k + needle.count)]) == needle { return k }
            k += 1
        }
        return nil
    }

    /// The first IPv4 address of an up, non-loopback interface (for the loopback-only bind check, PT-138).
    static func nonLoopbackIPv4() -> String? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            p = cur.pointee.ifa_next
        }
        return nil
    }
}

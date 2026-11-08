import Foundation
import Darwin

struct ShellResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var launchError: String?
    var ok: Bool { status == 0 && !timedOut && launchError == nil }
    var combined: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: stdout.hasSuffix("\n") || stdout.isEmpty ? "" : "\n")
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

enum Shell {
    static let searchPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Options for every ssh/scp to the phone. Each root image has its own host key for the same IP (iOS 18's is in
    /// ~/.ssh/known_hosts, iOS 26's in ~/.ssh/known_hosts_ios26); ssh accepts a key listed in any of these files.
    static let sshOptions = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3",
                             "-o", "UserKnownHostsFile=~/.ssh/known_hosts ~/.ssh/known_hosts_ios26"]

    /// PATH used for every child process (GUI apps start with a minimal PATH).
    static var childPath: String {
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>(), out: [String] = []
        for p in searchPaths + inherited where !p.isEmpty && seen.insert(p).inserted { out.append(p) }
        return out.joined(separator: ":")
    }

    /// Resolve a tool: explicit override first, then PATH + Homebrew locations.
    static func resolve(_ name: String, override: String = "") -> String? {
        let fm = FileManager.default
        let o = (override as NSString).expandingTildeInPath
        if !override.isEmpty { return fm.isExecutableFile(atPath: o) ? o : nil }
        for dir in childPath.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Run a program (no shell) off the main thread, with a timeout. `onOutput` streams merged output chunks.
    static func run(_ exe: String, _ args: [String] = [], cwd: String? = nil, env: [String: String] = [:],
                    timeout: TimeInterval = 10, onOutput: (@Sendable (String) -> Void)? = nil) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(exe, args, cwd: cwd, env: env, timeout: timeout, onOutput: onOutput))
            }
        }
    }

    static func runSync(_ exe: String, _ args: [String], cwd: String?, env: [String: String],
                        timeout: TimeInterval, onOutput: (@Sendable (String) -> Void)?) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = childPath
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["PYTHONUNBUFFERED"] = "1"
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let outBox = DataBox(), errBox = DataBox()
        let group = DispatchGroup()
        func attach(_ pipe: Pipe, _ box: DataBox) {
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; group.leave(); return }
                box.append(d)
                onOutput?(String(decoding: d, as: UTF8.self))
            }
        }
        attach(outPipe, outBox)
        attach(errPipe, errBox)
        do { try p.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return ShellResult(status: -1, stdout: "", stderr: "", timedOut: false, launchError: error.localizedDescription)
        }
        let timedOutFlag = DataBox()
        let killer = DispatchWorkItem {
            guard p.isRunning else { return }
            timedOutFlag.append(Data([1]))
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        _ = group.wait(timeout: .now() + 2)
        return ShellResult(status: p.terminationStatus, stdout: outBox.string, stderr: errBox.string,
                           timedOut: !timedOutFlag.string.isEmpty, launchError: nil)
    }

    /// TCP connect probe with timeout (non-blocking connect + poll).
    static func tcpOpen(host: String, port: UInt16, timeout: TimeInterval = 1.0) -> Bool {
        tcpProbe(host: host, port: port, timeout: timeout).open
    }

    /// Like `tcpOpen` but also reports errno (0 = ok, ETIMEDOUT on poll timeout).
    static func tcpProbe(host: String, port: UInt16, timeout: TimeInterval = 1.0) -> (open: Bool, err: Int32) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return (false, EINVAL) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (false, EINVAL) }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r == 0 { return (true, 0) }
        guard errno == EINPROGRESS else { return (false, EINVAL) }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return (false, EINVAL) }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return (err == 0, err)
    }

    /// True only when an SSH server really answers: connect, then read its "SSH-" banner within `timeout`.
    /// (iOS 18: the kernel accepted TCP 22 while dropbear was stalled, and Bergamota wrongly said iOS UP.)
    static func sshBanner(host: String, port: UInt16 = 22, timeout: TimeInterval = 3.0) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 {
            guard errno == EINPROGRESS else { return false }
            var w = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&w, 1, Int32(timeout * 1000)) > 0 else { return false }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return false }
        }
        var rd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&rd, 1, Int32(timeout * 1000)) > 0 else { return false }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &buf, buf.count)
        return n >= 4 && buf[0] == 0x53 && buf[1] == 0x53 && buf[2] == 0x48 && buf[3] == 0x2d   // "SSH-"
    }
}

func shellQuote(_ s: String) -> String {
    if !s.isEmpty && s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum DebugLog {
    static let path = NSHomeDirectory() + "/Library/Logs/Bergamota.log"
    private static let lock = NSLock()
    static func write(_ msg: String) {
        lock.lock(); defer { lock.unlock() }
        let f = ISO8601DateFormatter()
        let line = "\(f.string(from: Date())) \(msg)\n"
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}

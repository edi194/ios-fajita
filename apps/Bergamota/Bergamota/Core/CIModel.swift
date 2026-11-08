import Foundation
import Observation

struct CIRun: Identifiable, Decodable, Hashable, Sendable {
    var databaseId: Int
    var status: String
    var conclusion: String
    var headBranch: String
    var headSha: String
    var createdAt: Date
    var startedAt: Date?
    var updatedAt: Date?
    var displayTitle: String
    var url: String?
    var id: Int { databaseId }
    var shortSha: String { String(headSha.prefix(7)) }
    var isDone: Bool { status == "completed" }
    var duration: TimeInterval? {
        guard let u = updatedAt else { return nil }
        let s = startedAt ?? createdAt
        return max(0, u.timeIntervalSince(s))
    }
}

enum DownloadState: Equatable {
    case running
    case done(String)
    case failed(String)
}

@Observable
@MainActor
final class CIModel {
    static let branches = ["main", "ios18", "ci-cache"]

    var runs: [CIRun] = []
    var loading = false
    var error: String?
    var lastRefresh: Date?
    var downloads: [Int: DownloadState] = [:]
    var downloadLog = ""

    @ObservationIgnored private let settings: AppSettings
    init(settings: AppSettings) { self.settings = settings }

    func refresh() async {
        guard !loading else { return }
        guard let gh = settings.gh else { error = "gh not found (set it in Settings)"; return }
        loading = true
        defer { loading = false }
        let repo = settings.ghRepo
        var all: [CIRun] = []
        var errors: [String] = []
        await withTaskGroup(of: (([CIRun]?), String?).self) { group in
            for b in Self.branches {
                group.addTask {
                    let r = await Shell.run(gh, ["run", "list", "-R", repo, "-w", "xnu.yml", "-b", b, "-L", "8", "--json",
                                                 "databaseId,status,conclusion,headBranch,headSha,createdAt,startedAt,updatedAt,displayTitle,url"],
                                            timeout: 30)
                    guard r.ok else { return (nil, "\(b): " + (r.launchError ?? (r.timedOut ? "timed out" : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))) }
                    let dec = JSONDecoder()
                    dec.dateDecodingStrategy = .iso8601
                    do { return (try dec.decode([CIRun].self, from: Data(r.stdout.utf8)), nil) }
                    catch { return (nil, "\(b): parse error \(error.localizedDescription)") }
                }
            }
            for await (rs, e) in group { if let rs { all += rs }; if let e { errors.append(e) } }
        }
        runs = all.sorted { $0.createdAt > $1.createdAt }
        error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        lastRefresh = Date()
    }

    func outDir(for run: CIRun) -> String {
        "xnu/out-\(run.headBranch.replacingOccurrences(of: "/", with: "-"))-\(run.id)"
    }

    func downloadKernel(_ run: CIRun) async {
        guard let gh = settings.gh else { downloads[run.id] = .failed("gh not found"); return }
        guard downloads[run.id] != .running else { return }
        downloads[run.id] = .running
        let dir = outDir(for: run)
        let cmd = "gh run download \(run.id) -R \(settings.ghRepo) -n xnu-kernel -D \(dir)"
        downloadLog += "$ \(cmd)\n"
        let r = await Shell.run(gh, ["run", "download", String(run.id), "-R", settings.ghRepo, "-n", "xnu-kernel", "-D", dir],
                                cwd: settings.repoURL.path, timeout: 600)
        downloadLog += r.combined + (r.combined.hasSuffix("\n") || r.combined.isEmpty ? "" : "\n")
        if r.ok { downloads[run.id] = .done(dir); downloadLog += "-> \(dir)\n" }
        else {
            let msg = r.launchError ?? (r.timedOut ? "timed out" : r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            downloads[run.id] = .failed(msg.isEmpty ? "exit \(r.status)" : msg)
        }
    }

    func isDownloaded(_ run: CIRun) -> Bool {
        FileManager.default.fileExists(atPath: settings.repoFile(outDir(for: run)))
    }
}

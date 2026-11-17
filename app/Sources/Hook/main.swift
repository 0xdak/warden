import Foundation
import GuardCore

// warden-hook --agent claude|codex|cursor|gemini|windsurf|cline
// Reads the agent's hook JSON on stdin, decides, logs, and answers in the agent's dialect.
// Never exits 1 (that is "fail open" for most agents); unexpected problems → allow, so the agent keeps working.

let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
    if let a = args.first(where: { $0.hasPrefix(flag + "=") }) { return String(a.dropFirst(flag.count + 1)) }
    return nil
}

if args.contains("--version") {
    print("\(Brand.hookBinaryName) (\(Brand.appName)) \(Brand.version)")
    exit(0)
}
if args.contains("--ping") {
    let ok = GuardClient.ping()
    print(ok ? "\(Brand.appName) is running" : "\(Brand.appName) is not running")
    exit(ok ? 0 : 3)
}

// Terminal approvals (third delivery tier after the agent's own prompt and the app's popup):
//   warden-hook approvals                     list pending approvals
//   warden-hook approvals allow|project|block <id-prefix>
if args.count >= 2, args[1] == "approvals" {
    if args.count == 2 {
        guard let r = GuardClient.control(["type": "list"]) else { print("\(Brand.appName) is not running."); exit(3) }
        let items = r["pending"] as? [[String: Any]] ?? []
        if items.isEmpty { print("No pending approvals.") }
        for i in items {
            let id = String((i["id"] as? String ?? "").prefix(8))
            print("\(id)  \(i["agent"] ?? "")  \(i["rule"] ?? "")\n          \(i["summary"] ?? "")\n          in \(i["project"] ?? "")")
        }
        exit(0)
    }
    guard args.count == 4, ["allow", "project", "block"].contains(args[2]) else {
        print("usage: \(Brand.hookBinaryName) approvals [allow|project|block <id>]"); exit(64)
    }
    let decision = args[2] == "block" ? "block" : "allow"
    let scope = args[2] == "project" ? "project" : "once"
    guard let r = GuardClient.control(["type": "resolve", "id": args[3], "decision": decision, "scope": scope]) else {
        print("\(Brand.appName) is not running."); exit(3)
    }
    print((r["ok"] as? Bool) == true ? "Done." : "No pending approval matches \(args[3]).")
    exit((r["ok"] as? Bool) == true ? 0 : 1)
}

guard let name = value("--agent"), let agent = Agent(rawValue: name.lowercased()) else {
    FileHandle.standardError.write(Data("usage: \(Brand.hookBinaryName) --agent claude|codex|cursor|gemini|windsurf|cline\n".utf8))
    exit(0)
}

let input = FileHandle.standardInput.readDataToEndOfFile()

if args.contains("--explain") {
    // Dry run: print the matches and the decision, write nothing.
    let r = HookRunner.run(agent: agent, input: input, options: .init(scanAncestors: false, writeLog: false))
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
    if let d = try? enc.encode(r.matches) { print(String(decoding: d, as: UTF8.self)) }
    if let rec = r.record, let d = try? enc.encode(rec) { print(String(decoding: d, as: UTF8.self)) }
    print("exit=\(r.output.exitCode) stdout=\(r.output.stdout) stderr=\(r.output.stderr)")
    exit(0)
}

let result = HookRunner.run(agent: agent, input: input)
if !result.output.stdout.isEmpty { FileHandle.standardOutput.write(Data((result.output.stdout + "\n").utf8)) }
if !result.output.stderr.isEmpty { FileHandle.standardError.write(Data((result.output.stderr + "\n").utf8)) }
exit(result.output.exitCode)

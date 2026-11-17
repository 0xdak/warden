import Foundation

/// One simple command after prefix stripping (`sudo`, `env X=1`, `nohup`, `xargs`, …).
public struct ShellCommand: Sendable, Equatable {
    /// Unquoted words; argv[0] is the program as written.
    public var argv: [String]
    /// Targets of `>`, `>>`, `&>` (written) and `<` (read).
    public var redirOut: [String] = []
    public var redirIn: [String] = []
    public var viaSudo = false
    /// Run by `xargs`: the real operands arrive on stdin and aren't visible here.
    public var viaXargs = false
    /// Leading `NAME=value` words. When `argv` is empty this is a plain shell assignment (`f=.env; cat $f`).
    public var assigns: [String] = []
    /// Commands joined by `|` share a pipeline id; `;`, `&&`, `||`, `&` and newlines start a new one.
    public var pipeline: Int
    public var position: Int

    /// Program basename ("curl" for "/usr/bin/curl").
    public var name: String { argv.first.map { ($0 as NSString).lastPathComponent } ?? "" }
    public var args: [String] { Array(argv.dropFirst()) }
    /// Arguments that don't start with "-".
    public var operands: [String] { args.filter { !$0.hasPrefix("-") || $0 == "-" } }
    public var flags: [String] { args.filter { $0.hasPrefix("-") && $0 != "-" } }

    /// True when a short flag cluster or long flag is present ("-rf" contains "r").
    public func hasFlag(short: Character? = nil, long: String? = nil) -> Bool {
        for f in flags {
            if let long, f == "--\(long)" || f.hasPrefix("--\(long)=") { return true }
            if let short, !f.hasPrefix("--"), f.dropFirst().contains(short) { return true }
        }
        return false
    }
}

public struct ParsedShell: Sendable {
    public var raw: String
    public var commands: [ShellCommand]
    /// Every word seen (including inside nested commands), unquoted. Used for path scanning.
    public var allWords: [String]
}

/// A small, forgiving POSIX-ish shell lexer. It never executes anything; unknown syntax degrades to words.
public enum ShellLexer {
    enum Token: Equatable { case word(String), op(String) }

    public static func parse(_ raw: String) -> ParsedShell {
        var pipelineSeed = 0
        var commands: [ShellCommand] = []
        var words: [String] = []
        parse(raw, depth: 0, pipelineSeed: &pipelineSeed, into: &commands, words: &words)
        return ParsedShell(raw: raw, commands: commands, allWords: words)
    }

    private static func parse(_ raw: String, depth: Int, pipelineSeed: inout Int,
                              into commands: inout [ShellCommand], words: inout [String]) {
        guard depth < 5 else { return }
        var nested: [String] = []
        let tokens = tokenize(raw, nested: &nested)
        var cur: ShellCommand?
        var pos = 0
        var pendingRedir: String?

        func flush() {
            if var c = cur, !c.argv.isEmpty || !c.redirOut.isEmpty || !c.redirIn.isEmpty {
                strip(&c)
                if !c.argv.isEmpty || !c.redirOut.isEmpty || !c.redirIn.isEmpty || !c.assigns.isEmpty {
                    commands.append(c)
                    // `bash -c "…"`, `sh -c '…'`, `eval …` → parse the inner script too.
                    if ["sh", "bash", "zsh", "dash", "ksh", "fish"].contains(c.name),
                       let i = c.argv.firstIndex(where: { $0 == "-c" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.hasSuffix("c")) }),
                       i + 1 < c.argv.count {
                        nested.append(c.argv[i + 1])
                    } else if c.name == "eval", c.argv.count > 1 {
                        nested.append(c.argv.dropFirst().joined(separator: " "))
                    }
                }
            }
            cur = nil
        }

        for t in tokens {
            switch t {
            case .word(let w):
                words.append(w)
                if let r = pendingRedir {
                    if cur == nil { cur = ShellCommand(argv: [], pipeline: pipelineSeed, position: pos) }
                    if !(w.hasPrefix("&") || w.allSatisfy(\.isNumber)) {
                        if r == "<" { cur!.redirIn.append(w) } else { cur!.redirOut.append(w) }
                    }
                    pendingRedir = nil
                    continue
                }
                if cur == nil { cur = ShellCommand(argv: [], pipeline: pipelineSeed, position: pos) }
                cur!.argv.append(w)
            case .op(let o):
                switch o {
                case "|", "|&":
                    flush(); pos += 1
                case ">", ">>", "<", "&>", "&>>", ">|", "<>":
                    pendingRedir = (o == "<") ? "<" : ">"
                default: // ; && || & newline
                    flush(); pipelineSeed += 1; pos = 0
                }
            }
        }
        flush()
        pipelineSeed += 1
        for n in nested { parse(n, depth: depth + 1, pipelineSeed: &pipelineSeed, into: &commands, words: &words) }
    }

    /// Removes wrappers so argv[0] is the real program.
    static func strip(_ c: inout ShellCommand) {
        var a = c.argv[...]   // ArraySlice: removeFirst is O(1) (flag runs can be long)
        var guardCount = 0
        var sawWrapper = false
        while let first = a.first, guardCount < 12 {
            guardCount += 1
            let base = (first as NSString).lastPathComponent
            if isAssignment(first) {
                // Drop the whole run at once (removeFirst in a loop is quadratic on `a=1 b=2 …` × 10k).
                var k = 0
                while k < a.count, isAssignment(a[a.startIndex + k]) { k += 1 }
                if !sawWrapper { c.assigns += a.prefix(k) }   // only the leading run (before any wrapper) is recorded
                a.removeFirst(k)
                continue
            }
            sawWrapper = true
            switch base {
            case "sudo", "doas":
                c.viaSudo = true
                a.removeFirst()
                while let f = a.first, f.hasPrefix("-") {
                    a.removeFirst()
                    if ["-u", "-g", "-C", "-h", "-p", "-U", "-r", "-t", "-D"].contains(f), !a.isEmpty { a.removeFirst() }
                    if f == "--" { break }
                }
            case "env":
                if a.count == 1 { c.argv = Array(a); return }   // bare `env` = dump
                a.removeFirst()
                while let f = a.first, f.hasPrefix("-") || isAssignment(f) {
                    a.removeFirst()
                    if ["-u", "-S", "-P", "-C"].contains(f), !a.isEmpty { a.removeFirst() }
                }
                if a.isEmpty { c.argv = ["env"]; return }
            case "command", "builtin", "exec", "nohup", "time", "caffeinate", "stdbuf", "unbuffer":
                a.removeFirst()
                while let f = a.first, f.hasPrefix("-") { a.removeFirst() }
            case "nice", "ionice":
                a.removeFirst()
                while let f = a.first, f.hasPrefix("-") { a.removeFirst(); if f == "-n", !a.isEmpty { a.removeFirst() } }
            case "timeout", "gtimeout":
                a.removeFirst()
                while let f = a.first, f.hasPrefix("-") { a.removeFirst() }
                if !a.isEmpty { a.removeFirst() }   // duration
            case "xargs":
                c.viaXargs = true
                a.removeFirst()
                while let f = a.first, f.hasPrefix("-") {
                    a.removeFirst()
                    if ["-n", "-I", "-P", "-L", "-s", "-E", "-d"].contains(f), !a.isEmpty { a.removeFirst() }
                }
                if a.isEmpty { a = ["echo"] }
            default:
                c.argv = Array(a)
                return
            }
        }
        c.argv = Array(a)
    }

    static func isAssignment(_ w: String) -> Bool {
        guard let eq = w.firstIndex(of: "="), eq != w.startIndex else { return false }
        let name = w[w.startIndex..<eq]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !(name.first?.isNumber ?? true)
    }

    /// Decodes one escape of `$'…'` starting at the character after the backslash.
    static func ansiEscape(_ c: [Character], _ start: Int) -> (String, Int) {
        let ch = c[start]
        func hex(_ from: Int, max: Int) -> (String, Int) {
            var j = from, v = ""
            while j < c.count, v.count < max, c[j].isHexDigit { v.append(c[j]); j += 1 }
            guard let n = UInt32(v, radix: 16), let u = Unicode.Scalar(n) else { return ("", j) }
            return (String(Character(u)), j)
        }
        switch ch {
        case "n": return ("\n", start + 1)
        case "t": return ("\t", start + 1)
        case "r": return ("\r", start + 1)
        case "a", "b", "e", "E", "f", "v": return ("", start + 1)
        case "x": return hex(start + 1, max: 2)
        case "u": return hex(start + 1, max: 4)
        case "U": return hex(start + 1, max: 8)
        case "0", "1", "2", "3", "4", "5", "6", "7":
            var j = start, v = ""
            while j < c.count, v.count < 3, ("0"..."7").contains(c[j]) { v.append(c[j]); j += 1 }
            guard let n = UInt32(v, radix: 8), let u = Unicode.Scalar(n) else { return ("", j) }
            return (String(Character(u)), j)
        default: return (String(ch), start + 1)
        }
    }

    // MARK: Tokenizer

    static func tokenize(_ s: String, nested: inout [String]) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        var word = ""
        var inWord = false

        func endWord() {
            if inWord { tokens.append(.word(word)) }
            word = ""; inWord = false
        }

        /// Reads a balanced `( … )` starting after the opening paren; returns inner text and index after `)`.
        func readParen(_ start: Int) -> (String, Int) {
            var depth = 1
            var j = start
            var inS = false, inD = false
            while j < chars.count {
                let ch = chars[j]
                if inS { if ch == "'" { inS = false } }
                else if inD { if ch == "\\" { j += 1 } else if ch == "\"" { inD = false } }
                else if ch == "'" { inS = true }
                else if ch == "\"" { inD = true }
                else if ch == "\\" { j += 1 }
                else if ch == "(" { depth += 1 }
                else if ch == ")" { depth -= 1; if depth == 0 { return (String(chars[start..<j]), j + 1) } }
                j += 1
            }
            return (String(chars[start..<min(j, chars.count)]), chars.count)
        }

        func readBacktick(_ start: Int) -> (String, Int) {
            var j = start
            while j < chars.count, chars[j] != "`" { if chars[j] == "\\" { j += 1 }; j += 1 }
            return (String(chars[start..<min(j, chars.count)]), min(j + 1, chars.count))
        }

        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case " ", "\t":
                endWord(); i += 1
            case "\n", ";":
                endWord(); tokens.append(.op(";")); i += 1
            case "#" where !inWord:
                while i < chars.count, chars[i] != "\n" { i += 1 }
            case "'":
                inWord = true
                i += 1
                while i < chars.count, chars[i] != "'" { word.append(chars[i]); i += 1 }
                i += 1
            case "\"":
                inWord = true
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) {
                        word.append(chars[i + 1]); i += 2; continue
                    }
                    if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                        let (inner, next) = readParen(i + 2)
                        nested.append(inner); word += "$(\(inner))"; i = next; continue
                    }
                    if chars[i] == "`" {
                        let (inner, next) = readBacktick(i + 1)
                        nested.append(inner); word += "`\(inner)`"; i = next; continue
                    }
                    word.append(chars[i]); i += 1
                }
                i += 1
            case "\\":
                inWord = true
                if i + 1 < chars.count {
                    if chars[i + 1] != "\n" { word.append(chars[i + 1]) }
                    i += 2
                } else { i += 1 }
            case "$" where i + 1 < chars.count && chars[i + 1] == "'":
                // ANSI-C quoting: $'\x2eenv' is ".env" to the shell, so decode it the same way.
                inWord = true
                i += 2
                while i < chars.count, chars[i] != "'" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        let (decoded, next) = ansiEscape(chars, i + 1)
                        word += decoded; i = next; continue
                    }
                    word.append(chars[i]); i += 1
                }
                i += 1
            case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                inWord = true
                if i + 2 < chars.count, chars[i + 2] == "(" {          // $(( arithmetic ))
                    let (inner, next) = readParen(i + 2); word += "$(\(inner))"; i = next
                } else {
                    let (inner, next) = readParen(i + 2)
                    nested.append(inner); word += "$(\(inner))"; i = next
                }
            case "`":
                inWord = true
                let (inner, next) = readBacktick(i + 1)
                nested.append(inner); word += "`\(inner)`"; i = next
            case "<" where i + 1 < chars.count && chars[i + 1] == "(", ">" where i + 1 < chars.count && chars[i + 1] == "(":
                // Process substitution <( … ) / >( … )
                endWord()
                let (inner, next) = readParen(i + 2)
                nested.append(inner)
                tokens.append(.word("<(\(inner))"))
                i = next
            case "|":
                endWord()
                if i + 1 < chars.count, chars[i + 1] == "|" { tokens.append(.op("||")); i += 2 }
                else if i + 1 < chars.count, chars[i + 1] == "&" { tokens.append(.op("|&")); i += 2 }
                else { tokens.append(.op("|")); i += 1 }
            case "&":
                if i + 1 < chars.count, chars[i + 1] == "&" { endWord(); tokens.append(.op("&&")); i += 2 }
                else if i + 1 < chars.count, chars[i + 1] == ">" {
                    endWord()
                    if i + 2 < chars.count, chars[i + 2] == ">" { tokens.append(.op("&>>")); i += 3 } else { tokens.append(.op("&>")); i += 2 }
                } else if inWord, word.hasSuffix(">") == false, i > 0, chars[i - 1] == ">" {
                    word.append(ch); i += 1
                } else { endWord(); tokens.append(.op("&")); i += 1 }
            case ">", "<":
                // "2>" / "1>>": a pure-digit word right before is an fd number, not an argument.
                if inWord, word.allSatisfy(\.isNumber), !word.isEmpty { word = ""; inWord = false } else { endWord() }
                if ch == ">", i + 1 < chars.count, chars[i + 1] == ">" { tokens.append(.op(">>")); i += 2 }
                else if ch == ">", i + 1 < chars.count, chars[i + 1] == "&" {
                    // >&2 : duplicate fd, swallow target
                    i += 2
                    while i < chars.count, chars[i].isNumber || chars[i] == "-" { i += 1 }
                } else if ch == ">", i + 1 < chars.count, chars[i + 1] == "|" { tokens.append(.op(">|")); i += 2 }
                else if ch == "<", i + 1 < chars.count, chars[i + 1] == "<" {
                    // here-doc / here-string: skip operator, keep following word as plain word
                    i += 2
                    if i < chars.count, chars[i] == "<" { i += 1 }
                    tokens.append(.op("<<"))
                } else { tokens.append(.op(String(ch))); i += 1 }
            case ")":
                endWord(); tokens.append(.op(";")); i += 1
            case "(", "{", "}":
                if inWord { word.append(ch); i += 1 } else { tokens.append(.op(";")); i += 1 }
            default:
                inWord = true; word.append(ch); i += 1
            }
        }
        endWord()
        // Here-doc markers: treat "<<" like a separator of the delimiter word (drop the delimiter).
        var out: [Token] = []
        var skipNext = false
        for t in tokens {
            if skipNext, case .word = t { skipNext = false; continue }
            if t == .op("<<") { skipNext = true; continue }
            out.append(t)
        }
        return out
    }
}

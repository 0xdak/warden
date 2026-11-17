import Foundation

/// Masks secret-looking values before anything is written to the activity log.
public enum Redactor {
    public static let mask = "••••"

    struct Pattern { let re: NSRegularExpression; let keepGroup: Int? }

    static let patterns: [Pattern] = {
        let specs: [(String, Int?)] = [
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#, nil),
            (#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#, nil),
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#, nil),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#, nil),
            (#"\bglpat-[A-Za-z0-9_\-]{20,}\b"#, nil),
            (#"\bsk-(ant-|proj-)?[A-Za-z0-9_\-]{20,}\b"#, nil),
            (#"\b(sk|rk|pk)_(live|test)_[A-Za-z0-9]{10,}\b"#, nil),
            (#"\bxox[abposr]-[A-Za-z0-9\-]{10,}\b"#, nil),
            (#"\bAIza[0-9A-Za-z_\-]{35}\b"#, nil),
            (#"\bnpm_[A-Za-z0-9]{36}\b"#, nil),
            (#"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#, nil),
            // Authorization: Bearer xxx / Basic xxx
            (#"(?i)(authorization:\s*(bearer|basic|token)\s+)[^\s'"]+"#, 1),
            // KEY=value, "token": "value", --password value, password=… (keep the name)
            (#"(?i)(\b[A-Z0-9_]*(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIALS?)[A-Z0-9_]*\s*[=:]\s*["']?)[^\s"'&]+"#, 1),
            (#"(?i)(--?(password|passwd|token|secret|api-key|apikey)[= ]\s*["']?)[^\s"']+"#, 1),
            // mysql -pPASSWORD (password glued to -p), MYSQL_PWD=…, sshpass -p …, redis-cli -a …
            (#"(\b(?:mysql|mysqldump|mysqladmin|mysqlimport|mysqlsh|mariadb|mariadb-dump)\b[^\n|;&]*?\s-p["']?)[^\s"']+"#, 1),
            (#"(\bMYSQL_PWD\s*=\s*["']?)[^\s"']+"#, 1),
            (#"(\bsshpass\s+-p\s*["']?)[^\s"']+"#, 1),
            (#"(\bredis-cli\b[^\n|;&]*?\s-a\s+["']?)[^\s"']+"#, 1),
            // https://user:pass@host
            (#"(://[^/\s:@]+:)[^@/\s]+(@)"#, 1),
        ]
        return specs.compactMap { (p, g) in (try? NSRegularExpression(pattern: p)).map { Pattern(re: $0, keepGroup: g) } }
    }()

    public static func redact(_ s: String, limit: Int = 4000) -> String {
        var out = s.count > limit ? String(s.prefix(limit)) + "…" : s
        for p in patterns {
            let ns = out as NSString
            let matches = p.re.matches(in: out, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            var result = ""
            var last = 0
            for m in matches {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                if let g = p.keepGroup, m.range(at: g).location != NSNotFound {
                    result += ns.substring(with: m.range(at: g)) + mask
                    // keep trailing "@" for URL credentials
                    if m.numberOfRanges > 2, p.re.pattern.hasSuffix("(@)"), m.range(at: 2).location != NSNotFound {
                        result += "@"
                    }
                } else {
                    result += mask
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }

    public static func containsSecret(_ s: String) -> Bool { redact(s, limit: Int.max) != s }
}

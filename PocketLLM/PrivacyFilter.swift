import Foundation

enum PrivacyEntityKind: String, CaseIterable, Hashable {
    case accountNumber
    case privateAddress
    case privateDate
    case privatePerson
    case email
    case phone
    case url
    case ipAddress
    case idNumber
    case bankCard
    case secret

    var replacementText: String {
        switch self {
        case .accountNumber:
            return "[已隐藏账号]"
        case .privateAddress:
            return "[已隐藏地址]"
        case .privateDate:
            return "[已隐藏日期]"
        case .privatePerson:
            return "[已隐藏姓名]"
        case .email:
            return "[已隐藏邮箱]"
        case .phone:
            return "[已隐藏电话]"
        case .url:
            return "[已隐藏链接]"
        case .ipAddress:
            return "[已隐藏 IP]"
        case .idNumber:
            return "[已隐藏证件号]"
        case .bankCard:
            return "[已隐藏卡号]"
        case .secret:
            return "[已隐藏密钥]"
        }
    }

    var displayName: String {
        switch self {
        case .accountNumber:
            return "账号"
        case .privateAddress:
            return "地址"
        case .privateDate:
            return "日期"
        case .privatePerson:
            return "姓名"
        case .email:
            return "邮箱"
        case .phone:
            return "电话"
        case .url:
            return "链接"
        case .ipAddress:
            return "IP"
        case .idNumber:
            return "证件号"
        case .bankCard:
            return "卡号"
        case .secret:
            return "密钥"
        }
    }
}

struct PrivacyFinding: Hashable {
    let kind: PrivacyEntityKind
    let count: Int
}

struct PrivacyFilterResult: Equatable {
    let originalText: String
    let sanitizedText: String
    let findings: [PrivacyFinding]

    var didRedact: Bool {
        sanitizedText != originalText
    }

    static func passthrough(_ text: String) -> PrivacyFilterResult {
        PrivacyFilterResult(originalText: text, sanitizedText: text, findings: [])
    }

    var summary: String? {
        guard !findings.isEmpty else { return nil }
        let components = findings.map { finding in
            if finding.count == 1 {
                return finding.kind.displayName
            }
            return "\(finding.kind.displayName)×\(finding.count)"
        }
        return "已自动隐藏：\(components.joined(separator: "、"))"
    }
}

protocol PrivacyFiltering {
    func sanitize(text: String) -> PrivacyFilterResult
}

struct RegexPrivacyFilter: PrivacyFiltering {
    private struct Rule {
        let kind: PrivacyEntityKind
        let pattern: String
        let replacement: String
        let options: NSRegularExpression.Options
    }

    private let rules: [Rule] = [
        Rule(kind: .secret, pattern: #"(?i)(["']?)(api[_-]?key|token|secret|password)\1(\s*[:=]\s*)(["']?)[^\s"',;]{6,}\4"#, replacement: "$1$2$1$3$4[已隐藏密钥]$4", options: []),
        Rule(kind: .email, pattern: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, replacement: PrivacyEntityKind.email.replacementText, options: []),
        Rule(kind: .url, pattern: #"(?i)\b(?:https?://|www\.)\S+"#, replacement: PrivacyEntityKind.url.replacementText, options: []),
        Rule(kind: .ipAddress, pattern: #"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?!\d)"#, replacement: PrivacyEntityKind.ipAddress.replacementText, options: []),
        Rule(kind: .idNumber, pattern: #"(?<!\d)\d{17}[\dXx](?!\d)"#, replacement: PrivacyEntityKind.idNumber.replacementText, options: []),
        Rule(kind: .bankCard, pattern: #"(?<!\d)(?:\d[ -]?){13,19}(?!\d)"#, replacement: PrivacyEntityKind.bankCard.replacementText, options: []),
        Rule(kind: .phone, pattern: #"(?<!\d)(?:\+?\d[\d\-\s()]{6,}\d)(?!\d)"#, replacement: PrivacyEntityKind.phone.replacementText, options: [])
    ]

    func sanitize(text: String) -> PrivacyFilterResult {
        guard !text.isEmpty else { return .passthrough(text) }

        var sanitizedText = text
        var findings: [PrivacyFinding] = []

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else {
                continue
            }

            let range = NSRange(sanitizedText.startIndex..., in: sanitizedText)
            let matchCount = regex.numberOfMatches(in: sanitizedText, options: [], range: range)
            guard matchCount > 0 else { continue }

            sanitizedText = regex.stringByReplacingMatches(
                in: sanitizedText,
                options: [],
                range: range,
                withTemplate: rule.replacement
            )
            findings.append(PrivacyFinding(kind: rule.kind, count: matchCount))
        }

        return PrivacyFilterResult(originalText: text, sanitizedText: sanitizedText, findings: findings)
    }
}

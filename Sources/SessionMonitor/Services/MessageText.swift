import Foundation

enum MessageText {
    static let limit = 8000
    static func extract(_ content: Any?) -> String? {
        if let text = content as? String { return text.nilIfEmpty }
        guard let blocks = content as? [[String: Any]] else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard ["text", "input_text", "output_text"].contains(block["type"] as? String ?? "") else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n\n")
        return text.nilIfEmpty
    }
    static func preview(_ text: String?, role: String, at: Date?, coverage: String = "Last message found in the recent transcript tail", sourceTruncated: Bool = false) -> MessagePreview? {
        guard ["user", "assistant"].contains(role), let text else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return MessagePreview(text: String(clean.prefix(limit)), role: role, recordedAt: at,
                              truncated: sourceTruncated || clean.count > limit, coverage: coverage)
    }
    static func stored(_ value: String, role: String, at: Date?, sourceTruncated: Bool) -> MessagePreview? {
        let object = value.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let text: String?
        if let object { text = extract(object) }
        else if sourceTruncated && (value.hasPrefix("[{\"") || value.hasPrefix("{\"")) { return nil }
        else { text = value }
        return preview(text, role: role, at: at, coverage: "Last stored conversation message", sourceTruncated: sourceTruncated)
    }
}

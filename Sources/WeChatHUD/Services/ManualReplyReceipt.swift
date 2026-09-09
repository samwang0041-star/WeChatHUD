import Foundation

/// Confirms a manually triggered reply against the account-local WeChat
/// snapshot. The send key alone is not treated as delivery.
enum ManualReplyReceipt {
    static func confirms(
        messages: [MessageInfo],
        previousIDs: Set<String>,
        chatUsername: String,
        expectedText: String,
        startedAt: Int,
        myUsername: String,
        myDisplayName: String,
        mySelfNames: Set<String>
    ) -> Bool {
        let expected = expectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return false }
        let normalizedExpected = normalize(expected)
        return messages.contains { message in
            guard !previousIDs.contains(message.id) else { return false }
            guard message.createTime >= startedAt - 2 else { return false }
            guard normalize(message.text) == normalizedExpected else { return false }
            return MessageHelpers.isFromSelf(
                message,
                chatUsername: chatUsername,
                myUsername: myUsername,
                myDisplayName: myDisplayName,
                mySelfNames: mySelfNames
            )
        }
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

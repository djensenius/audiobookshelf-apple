import Foundation

extension AccountManager {
    /// Every custom header value saved for a listed connection or sent by the active client,
    /// sorted and without duplicates, for ``LogsModel/load(secrets:)``.
    ///
    /// ``Redactor`` can't recognise a header value by pattern, so the Logs screen and its export
    /// pass these in to remove them (#662). A connection whose headers can't be read is skipped;
    /// values from a connection removed earlier in the launch are no longer known.
    public func customHeaderValuesForLogs() async -> [String] {
        let active = await client?.configuration.customHeaders ?? [:]
        var values = Set(active.values)
        for connection in connections {
            if let headers = try? await customHeaders(for: connection.id) {
                values.formUnion(headers.values)
            }
        }
        return values.sorted()
    }
}

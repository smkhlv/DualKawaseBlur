import Foundation

struct BenchmarkExport: Codable, Sendable {
    let schemaVersion: Int
    let records: [BenchmarkRecord]

    func validatedJSON() throws -> Data {
        try records.forEach { try $0.validate() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

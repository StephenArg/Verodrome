import Foundation

public enum XmlParseError: Error, Sendable, LocalizedError {
    case invalidData
    case parserFailed(String)
    case missingRootElement(String)
    case serverError(code: Int?, message: String)
    case unexpectedStructure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Response body was not valid XML."
        case .parserFailed(let detail):
            return "XML parsing failed: \(detail)"
        case .missingRootElement(let name):
            return "Expected root element '\(name)' was not found."
        case .serverError(let code, let message):
            if let code {
                return "Server error \(code): \(message)"
            }
            return "Server error: \(message)"
        case .unexpectedStructure(let detail):
            return "Unexpected XML structure: \(detail)"
        }
    }
}

package enum DocumentationSearchBackendError: Error, Sendable {
    case unavailable
    case invalidResponse(String)
}

package func documentationSearchTextEncoderInitializationFailed(_ text: String) -> Bool {
    let normalized = text.lowercased()
    return normalized.contains("text encoding failed")
        || normalized.contains("failed to create text encoder configuration")
        || normalized.contains("text embedding model file not found")
}

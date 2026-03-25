import Foundation

func debugLog(_ message: String) {
    let msg = message + "\n"
    if let data = msg.data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

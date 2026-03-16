import Foundation

struct SessionFolder: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var isExpanded: Bool = true
}

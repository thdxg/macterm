import Foundation

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var sortOrder: Int
    var createdAt: Date

    init(name: String, path: String, sortOrder: Int = 0) {
        id = UUID()
        self.name = name
        self.path = path
        self.sortOrder = sortOrder
        createdAt = Date()
    }
}

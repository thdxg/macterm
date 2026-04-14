import Foundation
import os

private let logger = Logger(subsystem: "com.thdxg.macterm", category: "ProjectStore")

@MainActor @Observable
final class ProjectStore {
    private(set) var projects: [Project] = []
    private let fileURL: URL

    init(fileURL: URL = FileStorage.fileURL(filename: "projects.json")) {
        self.fileURL = fileURL
        load()
    }

    func add(_ project: Project) {
        projects.append(project)
        save()
    }

    func remove(id: UUID) {
        projects.removeAll { $0.id == id }
        save()
    }

    func rename(id: UUID, to newName: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = newName
        save()
    }

    func reorder(fromOffsets source: IndexSet, toOffset destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        for i in projects.indices {
            projects[i].sortOrder = i
        }
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(projects)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save projects: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            projects = try JSONDecoder().decode([Project].self, from: data)
            projects.sort { $0.sortOrder < $1.sortOrder }
        } catch {
            logger.error("Failed to load projects: \(error)")
        }
    }
}

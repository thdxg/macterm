import Foundation
@testable import Macterm
import Testing

@MainActor
struct ProjectMemoryStoreTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("macterm-memory-\(UUID().uuidString)", isDirectory: true)
    }

    private func entry(_ command: String, exit: Int? = 0, at date: Date = Date()) -> MemoryEntry {
        MemoryEntry(command: command, directory: "/tmp", exitCode: exit, finishedAt: date, duration: 1)
    }

    @Test
    func entries_survive_a_new_store_after_a_flush() {
        let directory = makeDirectory()
        let project = UUID()
        let store = ProjectMemoryStore(directory: directory)
        store.append(entry("make"), to: project)
        store.append(entry("make test", exit: 2), to: project)
        store.flush()

        let reread = ProjectMemoryStore(directory: directory)
        #expect(reread.entries(for: project).map(\.command) == ["make", "make test"])
        #expect(reread.entries(for: project).last?.exitCode == 2)
    }

    @Test
    func the_ring_drops_the_oldest_entries() {
        let store = ProjectMemoryStore(directory: makeDirectory())
        let project = UUID()
        for index in 0 ..< ProjectMemoryStore.capacity + 5 {
            store.append(entry("cmd \(index)"), to: project)
        }
        let entries = store.entries(for: project)
        #expect(entries.count == ProjectMemoryStore.capacity)
        #expect(entries.first?.command == "cmd 5")
    }

    @Test
    func a_file_that_does_not_decode_is_never_written_over() throws {
        let directory = makeDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let project = UUID()
        let store = ProjectMemoryStore(directory: directory)
        let url = store.fileURL(for: project)
        try Data("not json".utf8).write(to: url)

        store.append(entry("make"), to: project)
        store.flush()

        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")
    }

    @Test
    func forget_deletes_the_file() {
        let directory = makeDirectory()
        let project = UUID()
        let store = ProjectMemoryStore(directory: directory)
        store.append(entry("make"), to: project)
        store.flush()
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: project).path))

        store.forget(project)

        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: project).path))
        #expect(store.entries(for: project).isEmpty)
    }

    @Test
    func prune_deletes_only_the_files_of_removed_projects() {
        let directory = makeDirectory()
        let kept = UUID()
        let removed = UUID()
        let store = ProjectMemoryStore(directory: directory)
        store.append(entry("a"), to: kept)
        store.append(entry("b"), to: removed)
        store.flush()

        store.prune(keeping: [kept])

        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: kept).path))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: removed).path))
    }

    @Test
    func a_view_read_never_touches_the_disk() {
        let directory = makeDirectory()
        let project = UUID()
        let writer = ProjectMemoryStore(directory: directory)
        writer.append(entry("make"), to: project)
        writer.flush()

        let reader = ProjectMemoryStore(directory: directory)
        #expect(reader.loadedEntries(for: project).isEmpty)
        reader.prepare(project)
        #expect(reader.loadedEntries(for: project).map(\.command) == ["make"])
    }
}

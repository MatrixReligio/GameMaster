import Foundation
import GMBottles
import GMLaunch
import GMModel

/// Adds and removes user-chosen Windows programs in a bottle's library.
public struct ProgramLibrary: Sendable {
    private let bottleStore: BottleStore

    public init(bottleStore: BottleStore) {
        self.bottleStore = bottleStore
    }

    @discardableResult
    public func addProgram(exe: URL, name: String?, in bottle: Bottle) async throws -> Program {
        let prefix = await bottleStore.prefixDirectory(of: bottle)
        let program = Program(
            name: name ?? exe.deletingPathExtension().lastPathComponent,
            windowsPath: WindowsPath.toWindows(exe, prefix: prefix),
            pinned: true
        )
        let bottleDirectory = await bottleStore.directory(of: bottle)
        ProgramIconStore.extractAndStore(exe: exe, programID: program.id, bottleDirectory: bottleDirectory)
        // Transactional append: the caller's snapshot may be stale (a rename
        // or install may have landed since), so only the programs array is
        // read-modify-written inside the store.
        try await bottleStore.update(id: bottle.id) { $0.programs.append(program) }
        return program
    }

    public func removeProgram(id: UUID, from bottle: Bottle) async throws {
        let bottleDirectory = await bottleStore.directory(of: bottle)
        ProgramIconStore.removeIcon(programID: id, bottleDirectory: bottleDirectory)
        try await bottleStore.update(id: bottle.id) { $0.programs.removeAll { $0.id == id } }
    }
}

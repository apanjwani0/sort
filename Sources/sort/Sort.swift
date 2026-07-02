import ArgumentParser
import Foundation
import SortKit

@main
struct Sort: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sort",
        abstract: "Browse any folder or drive's photos grouped by face — read-only.",
        version: SortKit.version,
        subcommands: [Scan.self, People.self, Photos.self, Name.self, Delete.self, Faces.self,
                      Reclassify.self]
    )
}

// MARK: - Shared helpers

private func openDatabase(_ path: String?) throws -> AppDatabase {
    let url = try path.map { URL(fileURLWithPath: $0) } ?? AppDatabase.defaultURL()
    return try AppDatabase.onDisk(at: url)
}

struct DBOption: ParsableArguments {
    @Option(name: .long, help: "Index database path (default: ~/Library/Application Support/sort/index.sqlite).")
    var db: String?
}

// MARK: - scan

extension Sort {
    struct Scan: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Scan a folder or mounted drive, detect + group faces (originals untouched).")

        @Argument(help: "Folder or mounted-drive path to scan.")
        var path: String

        @Option(name: .long, help: "Clustering distance threshold (lower = more conservative).")
        var threshold: Float = 0.45

        @Option(name: .long, help: "Path to an ArcFace .mlmodelc (default: Vision feature print).")
        var model: String?

        @OptionGroup var dbOption: DBOption

        func run() throws {
            let database = try openDatabase(dbOption.db)
            let service = IndexService(db: database)
            let now = Date().timeIntervalSince1970
            let embedder = EmbedderFactory.makeDefault(modelURL: model.map { URL(fileURLWithPath: $0) })

            FileHandle.standardError.write(Data("Scanning \(path) … [embedder: \(embedder.modelIdentifier)]\n".utf8))
            var lastPhase: IndexService.Progress.Phase?
            let report = try service.index(rootPath: path,
                                           embedder: embedder,
                                           clustering: .init(threshold: threshold),
                                           now: now) { p in
                if p.phase != lastPhase {
                    lastPhase = p.phase
                    FileHandle.standardError.write(Data("  \(p.phase.rawValue) …\n".utf8))
                }
            }

            print("""
            Scan complete:
              discovered \(report.scan.discovered), changed \(report.scan.changed), \
            unchanged \(report.scan.unchanged), missing \(report.scan.missing)
              processed \(report.photosProcessed) photos, \(report.failures) failed
              faces \(report.facesAdded), people \(report.recluster.people) \
            (\(report.recluster.reusedPeople) kept, \(report.recluster.newPeople) new)
            Run `sort people` to browse.
            """)
        }
    }
}

// MARK: - people

extension Sort {
    struct People: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List grouped people by face count.")

        @Flag(name: .long, help: "Include hidden people.")
        var includeHidden = false

        @OptionGroup var dbOption: DBOption

        func run() throws {
            let service = IndexService(db: try openDatabase(dbOption.db))
            let people = try service.people(includeHidden: includeHidden)
            if people.isEmpty { print("No people yet — run `sort scan <folder>` first."); return }
            print("\(people.count) people:")
            for p in people {
                let name = p.displayName ?? "Unnamed"
                print("  [\(p.id ?? -1)] \(name) — \(p.faceCount) face\(p.faceCount == 1 ? "" : "s")")
            }
        }
    }
}

// MARK: - photos

extension Sort {
    struct Photos: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List photos for a person id.")

        @Argument(help: "Person id (from `sort people`).")
        var personId: Int64

        @OptionGroup var dbOption: DBOption

        func run() throws {
            let service = IndexService(db: try openDatabase(dbOption.db))
            let rootPath = Dictionary(uniqueKeysWithValues:
                try service.scannedRoots().compactMap { r in r.id.map { ($0, r.displayPath) } })
            let photos = try service.photos(forPerson: personId)
            if photos.isEmpty { print("No photos for person \(personId)."); return }
            for photo in photos {
                let base = rootPath[photo.rootId] ?? ""
                let path = base.isEmpty ? photo.relativePath : "\(base)/\(photo.relativePath)"
                print("[\(photo.id ?? -1)] \(path)")
            }
        }
    }
}

// MARK: - delete

extension Sort {
    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move photos to the Trash and remove them from the index (recoverable).")

        @Argument(help: "Photo ids to delete (from `sort photos <person>`).")
        var photoIds: [Int64]

        @Flag(name: .shortAndLong, help: "Skip the confirmation prompt.")
        var yes = false

        @OptionGroup var dbOption: DBOption

        func run() throws {
            guard !photoIds.isEmpty else { print("No photo ids given."); return }
            if !yes {
                FileHandle.standardError.write(Data("Move \(photoIds.count) photo(s) to the Trash? [y/N] ".utf8))
                guard (readLine() ?? "").lowercased().hasPrefix("y") else { print("Cancelled."); return }
            }
            let service = IndexService(db: try openDatabase(dbOption.db))
            let r = try service.deletePhotos(ids: photoIds, now: Date().timeIntervalSince1970)
            print("Trashed \(r.trashed), missing \(r.missing), failed \(r.failed); pruned \(r.removedPeople) empty people.")
        }
    }
}

// MARK: - reclassify

extension Sort {
    struct Reclassify: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Classify already-indexed photos into categories (screenshots / documents / …).")

        @OptionGroup var dbOption: DBOption

        func run() throws {
            let service = IndexService(db: try openDatabase(dbOption.db))
            FileHandle.standardError.write(Data("Classifying uncategorized photos …\n".utf8))
            let n = try service.classifyUncategorized()
            let c = try service.categoryCounts()
            print("Classified \(n) photos — screenshots \(c.screenshots), documents \(c.documents), "
                  + "places \(c.places), no-faces \(c.noFaces).")
        }
    }
}

// MARK: - faces

extension Sort {
    struct Faces: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List detected face boxes in a photo (powers the highlight overlay).")

        @Argument(help: "Photo id.")
        var photoId: Int64

        @Option(name: .long, help: "Only faces of this person id.")
        var person: Int64?

        @OptionGroup var dbOption: DBOption

        func run() throws {
            let service = IndexService(db: try openDatabase(dbOption.db))
            let faces = try service.faces(inPhoto: photoId, person: person)
            if faces.isEmpty { print("No faces in photo \(photoId)."); return }
            func f(_ v: Double) -> String { String(format: "%.3f", v) }
            for face in faces {
                let who = face.personId.map(String.init) ?? "—"
                print("face \(face.id ?? -1) · person \(who) · "
                      + "bbox [x=\(f(face.bboxX)) y=\(f(face.bboxY)) w=\(f(face.bboxW)) h=\(f(face.bboxH))]")
            }
        }
    }
}

// MARK: - name

extension Sort {
    struct Name: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Name (or rename) a person.")

        @Argument(help: "Person id (from `sort people`).")
        var personId: Int64
        @Argument(help: "Display name.")
        var name: String

        @OptionGroup var dbOption: DBOption

        func run() throws {
            let service = IndexService(db: try openDatabase(dbOption.db))
            try service.renamePerson(personId, to: name, now: Date().timeIntervalSince1970)
            print("Named person \(personId) → \(name)")
        }
    }
}

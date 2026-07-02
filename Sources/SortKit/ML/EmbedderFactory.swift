import Foundation

/// Chooses the face embedder at runtime (D1/D6): the bundled/installed Core ML model when present,
/// otherwise the zero-setup Vision feature-print default. Because every embedding stores its
/// `embeddingModel`, switching models is detectable and a re-index re-embeds cleanly.
public enum EmbedderFactory {
    /// Core ML face models we know how to load, in preference order. **AuraFace v1** (Apache-2.0) is the
    /// commercial-clean model bundled in the public DMG; **arcface / buffalo_l** is an optional
    /// higher-accuracy *personal-use* swap — drop `arcface.mlmodelc` in the models dir (or pass
    /// `--model`) to prefer it. Both share the 112×112 / 512-d / BGR `(x-127.5)/127.5` contract.
    public static let knownModels: [(file: String, identifier: String, display: String)] = [
        ("auraface", "auraface.v1",       "AuraFace v1"),
        ("arcface",  "arcface.buffalo_l", "ArcFace · buffalo_l"),
    ]
    /// Generic identifier for a model passed explicitly via `--model` (whose provenance we can't know).
    public static let arcFaceIdentifier = "coreml.embedder"

    /// First available Core ML model: bundled inside the .app (sandbox-readable) first, then the
    /// conventional install dir `~/Library/Application Support/sort/models/<name>.mlmodelc` for the
    /// CLI / unsandboxed `swift run`.
    public static func installedModel() -> (url: URL, identifier: String, display: String)? {
        for m in knownModels {
            if let bundled = Bundle.main.url(forResource: m.file, withExtension: "mlmodelc") {
                return (bundled, m.identifier, m.display)
            }
        }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else { return nil }
        for m in knownModels {
            let url = base.appendingPathComponent("sort/models/\(m.file).mlmodelc")
            if FileManager.default.fileExists(atPath: url.path) { return (url, m.identifier, m.display) }
        }
        return nil
    }

    /// Back-compat: URL of the installed Core ML model, if any.
    public static func installedModelURL() -> URL? { installedModel()?.url }
    /// Display name of the installed Core ML model, if any (nil ⇒ none → Vision fallback).
    public static func installedModelName() -> String? { installedModel()?.display }
    /// What the engine will actually use, for Settings — accounts for the Vision override.
    public static func activeModelDisplayName() -> String {
        if UserDefaults.standard.string(forKey: "groupingModel") == "vision" { return "Vision feature-print" }
        return installedModel()?.display ?? "Vision feature-print (fallback)"
    }

    /// The best available embedder. Pass `modelURL` to force a specific `.mlmodelc`; otherwise the
    /// installed model is used if found, falling back to Vision. A `"groupingModel" == "vision"`
    /// preference (set by the Settings window via @AppStorage) forces Vision even if a model is installed.
    public static func makeDefault(modelURL: URL? = nil) -> FaceEmbedder {
        if UserDefaults.standard.string(forKey: "groupingModel") == "vision" {
            return VisionFeaturePrintEmbedder()
        }
        let pick: (url: URL, identifier: String)?
        if let modelURL { pick = (modelURL, arcFaceIdentifier) }
        else if let m = installedModel() { pick = (m.url, m.identifier) }
        else { pick = nil }
        if let pick, let coreml = try? CoreMLEmbedder(modelURL: pick.url, identifier: pick.identifier,
                                                      inputName: "image", outputName: "embedding", inputSize: 112) {
            return coreml
        }
        return VisionFeaturePrintEmbedder()
    }
}

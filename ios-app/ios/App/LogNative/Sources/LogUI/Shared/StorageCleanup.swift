import Foundation

/// Frees space left by older builds: the on-device models Ask used to download (gigabytes, in
/// Application Support/Models and the Hugging Face caches) and leftover export files in tmp.
/// Cheap to run on every launch; it only touches paths that exist.
public enum StorageCleanup {
    public static func run() {
        let fm = FileManager.default
        var paths: [URL] = []
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            paths.append(support.appendingPathComponent("Models", isDirectory: true))
        }
        for dir in [FileManager.SearchPathDirectory.documentDirectory, .cachesDirectory] {
            if let base = fm.urls(for: dir, in: .userDomainMask).first {
                paths.append(base.appendingPathComponent("huggingface", isDirectory: true))
                paths.append(base.appendingPathComponent("models", isDirectory: true))
            }
        }
        if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            // MLX's compiled Metal kernels.
            paths.append(caches.appendingPathComponent("mlx", isDirectory: true))
        }
        if let tmp = try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil) {
            paths.append(contentsOf: tmp)
        }
        for p in paths where fm.fileExists(atPath: p.path) {
            try? fm.removeItem(at: p)
        }
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("log.localModel") {
            defaults.removeObject(forKey: key)
        }
        if defaults.string(forKey: "log.askMode") == "local" { defaults.removeObject(forKey: "log.askMode") }
    }
}

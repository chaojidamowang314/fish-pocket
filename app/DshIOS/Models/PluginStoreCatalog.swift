import Foundation

/// What the store itself decides; everything about a plugin comes from its market index.
enum PluginStoreCatalog {
    /// The market a fresh install opens on.
    static let presetIndex = "https://api.dshfind.com/market/dsh-index.json"
}

/// A market listing as the store shows it. Index fields follow the format's rules; the rest of
/// what a row needs is derived here, so every page reads an entry the same way.
struct StoreEntry {
    let json: JSON

    var name: String { json["name"].string ?? "" }
    /// The package name without its scope.
    var shortName: String { name.components(separatedBy: "/").last ?? name }
    var scope: String? { name.hasPrefix("@") ? name.components(separatedBy: "/").first : nil }

    /// `title`, unless the index filled it with a repository path: a package name reads better.
    var displayName: String {
        guard let title = localized(json["title"]), !title.isEmpty,
              !(title.contains("/") && !title.contains(" ")) else { return name }
        return title
    }

    var summary: String? { localized(json["description"]).flatMap { $0.isEmpty ? nil : $0 } }
    var icon: String? { json["icon"].string }

    var version: JSON? { json["versions"].array.first { $0["version"].string == json["defaultVersion"].string } ?? json["versions"].array.first }
    var versionNumber: String { version?["version"].string ?? "" }
    var status: String? { json["installation"]["status"].string }
    var author: String? { json["author"].string }
    var labels: [String] { json["metadata"]["labels"].array.compactMap(\.string) }

    /// The default version's publish date.
    var date: String? {
        version?["publishTimestamp"].double.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) }
    }

    /// The running DSH accepts this version, or the user exempted it.
    var installable: Bool {
        guard let compatibility = version?["compatibility"] else { return false }
        return compatibility["compatible"].bool == true || compatibility["exempted"].bool == true
    }

    /// The category's title, from what this market declares.
    func category(in metadata: JSON) -> String? {
        guard let id = json["metadata"]["category"].string else { return nil }
        return localized(metadata["categories"][id]["title"]) ?? id
    }
}

extension StoreEntry: Identifiable {
    var id: String { name }
}

import Foundation

/// An Epic game's screenshots, from the pictures at the top of its store page (`StoreScreenshots` keeps them).
///
/// The page is found by its slug, which the launcher doesn't keep anywhere on disk. Epic's store GraphQL that
/// knows it sits behind a Cloudflare challenge, so the slug comes from Epic's public namespace → slug list, or
/// failing that from the game's name ("Before We Leave" → `before-we-leave`). A page is taken only when it names
/// the game's own namespace, so a guessed slug never shows another game's pictures.
enum EpicScreenshots {
    static let mapping = URL(string: "https://store-content-ipv4.ak.epicgames.com/api/content/productmapping")

    static func product(slug: String) -> URL? {
        guard !slug.isEmpty, slug.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
        else { return nil }
        return URL(string: "https://store-content-ipv4.ak.epicgames.com/api/en-US/content/products/\(slug)")
    }

    static func fetch(namespace: String, title: String) async -> [StoreScreenshots.Shot]? {
        var known: Data?
        if let mapping { known = try? await get(mapping) }
        for slug in slugs(namespace: namespace, title: title, mapping: known) {
            guard let url = product(slug: slug), let data = try? await get(url) else { continue }
            if let shots = parse(data, namespace: namespace) { return shots }
        }
        return nil
    }

    private static func get(_ url: URL) async throws -> Data? {
        let (data, response) = try await URLSession.shared.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode == 200 ? data : nil
    }

    /// The slugs to try, the list's first: `{"fn":"fortnite","6144…":"before-we-leave",…}`.
    static func slugs(namespace: String, title: String, mapping: Data?) -> [String] {
        let listed = mapping.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?[namespace]
        let guessed = slug(title: title)
        return [listed, guessed].compactMap { $0 }.filter { !$0.isEmpty }.reduce(into: []) { slugs, slug in
            if !slugs.contains(slug) { slugs.append(slug) }
        }
    }

    /// The store's own form of a name: "Assassin's Creed® Unity" → `assassins-creed-unity`.
    static func slug(title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))
            .lowercased()
        var slug = ""
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if character.isWhitespace || character == "-" || character == ":", !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// The pictures of the page's carousel (`pages[type=productHome].data.carousel.items[].image.src`), 1920×1080.
    /// Items that are videos have no picture and are left out. A page of another namespace gives nil.
    static func parse(_ data: Data, namespace: String) -> [StoreScreenshots.Shot]? {
        struct Product: Decodable {
            var namespace: String?
            var pages: [Page]?
        }
        struct Page: Decodable {
            var type: String?
            var namespace: String?
            var data: PageData?
        }
        struct PageData: Decodable { var carousel: Carousel? }
        struct Carousel: Decodable { var items: [Item]? }
        struct Item: Decodable { var image: Image? }
        struct Image: Decodable { var src: String? }

        guard let product = try? JSONDecoder().decode(Product.self, from: data) else { return nil }
        let pages = product.pages ?? []
        guard product.namespace == namespace || pages.contains(where: { $0.namespace == namespace }) else { return nil }
        let home = pages.first { $0.type == "productHome" } ?? pages.first
        let sources = (home?.data?.carousel?.items ?? []).compactMap { $0.image?.src }
        return sources.compactMap { URL(string: $0) }.filter(isEpics).enumerated().compactMap { index, full in
            thumbnail(of: full).map { .init(id: index, thumbnail: $0, full: full) }
        }
    }

    /// Epic's image servers resize on request: a 640×360 copy is a quarter of the full picture.
    static func thumbnail(of full: URL) -> URL? {
        guard var components = URLComponents(url: full, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [.init(name: "resize", value: "1"), .init(name: "w", value: "640"),
                                 .init(name: "h", value: "360"), .init(name: "quality", value: "medium")]
        return components.url
    }

    static func isEpics(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return ["epicgames.com", "unrealengine.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

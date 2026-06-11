import Foundation
import simd

/// Minimal client for Google's Photorealistic 3D Tiles (OGC 3D Tiles 1.0).
///
/// The API is a tree of tileset JSON documents. Each node carries a bounding
/// volume, a geometric error (a "how coarse is this" metric in metres), and
/// either child nodes (finer detail) or content — a Draco-compressed glTF
/// binary, or a nested tileset JSON to recurse into.
///
/// `collectTiles` walks the tree top-down, descending only into nodes whose
/// bounding volume intersects the park, until the geometric error is small
/// enough, and returns the GLB URLs to render. Google requires a `key` query
/// parameter on the root request and a `session` parameter (minted by the
/// root response, embedded in child URIs) on every request after it.
struct TileStreamer {

    struct Tile {
        let url: URL
        /// Geometric error of the node, kept for debugging/telemetry.
        let geometricError: Double
        /// Horizontal distance (m) from the park anchor; used to load
        /// nearest tiles first.
        let distance: Double
    }

    enum StreamError: Error {
        case badRootResponse
        case httpError(Int, URL)
    }

    let apiKey: String

    /// Hard cap on the number of GLBs fetched, as a memory backstop. Tiles
    /// are loaded nearest-first, so when the cap bites it's distant context
    /// that gets dropped, never the deck underfoot.
    var maxTiles = 450

    /// Distance-based level of detail: the geometric error (m) we'll accept
    /// for a node whose bounding volume is `distance` metres from the park
    /// anchor. Within ~75 m the target sits below Google's finest published
    /// level (leaves bottom out around 0.25–0.5 m GE), forcing descent to the
    /// true leaves; beyond that it grows linearly so the skyline stays cheap.
    /// The 70/30 constants are the quality/memory knobs.
    static func targetGeometricError(atDistance distance: Double) -> Double {
        min(max(0.2, (distance - 70.0) / 30.0), 20.0)
    }

    private let baseURL = URL(string: "https://tile.googleapis.com")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    // MARK: Tileset JSON model

    private struct Tileset: Decodable { let root: Node }

    private struct Node: Decodable {
        struct BoundingVolume: Decodable {
            /// [west, south, east, north, minHeight, maxHeight], radians + metres.
            let region: [Double]?
            /// [cx, cy, cz, xAxis…, yAxis…, zAxis…] oriented box in tileset coords (ECEF).
            let box: [Double]?
        }
        struct Content: Decodable { let uri: String }
        let boundingVolume: BoundingVolume
        let geometricError: Double
        let content: Content?
        let children: [Node]?
    }

    // MARK: Traversal

    /// Walks the tileset and streams render-ready tile URLs to `onTile` as
    /// they are discovered. Returns the total number of tiles selected.
    func collectTiles(onTile: @escaping (Tile) -> Void) async throws -> Int {
        var sessionToken: String?
        let rootData = try await fetch(uri: "/v1/3dtiles/root.json", sessionToken: &sessionToken)
        let rootTileset = try JSONDecoder().decode(Tileset.self, from: rootData)

        var count = 0
        // Nearest-first traversal (linear-scan priority queue; the frontier
        // stays small): when the tile budget runs out, what gets dropped is
        // distant skyline, never the deck underfoot.
        var frontier: [(node: Node, distance: Double)] = [
            (rootTileset.root, horizontalDistance(of: rootTileset.root.boundingVolume))
        ]
        while !frontier.isEmpty {
            if count >= maxTiles { break }
            var nearest = 0
            for index in frontier.indices where frontier[index].distance < frontier[nearest].distance {
                nearest = index
            }
            let (node, distance) = frontier.remove(at: nearest)
            guard intersectsPark(node.boundingVolume) else { continue }

            let children = node.children ?? []
            if node.geometricError > Self.targetGeometricError(atDistance: distance) {
                if !children.isEmpty {
                    frontier.append(contentsOf: children.map {
                        ($0, horizontalDistance(of: $0.boundingVolume))
                    })
                    continue
                }
                // Leaf-with-content whose content is a nested tileset.
                if let uri = node.content?.uri, uri.contains(".json") {
                    var token = sessionToken
                    let data = try await fetch(uri: uri, sessionToken: &token)
                    sessionToken = token ?? sessionToken
                    let nested = try JSONDecoder().decode(Tileset.self, from: data)
                    frontier.append((nested.root, horizontalDistance(of: nested.root.boundingVolume)))
                    continue
                }
            }
            // Detailed enough (or nothing finer available): take the GLB.
            if let uri = node.content?.uri, uri.contains(".glb") {
                if let url = requestURL(uri: uri, sessionToken: sessionToken) {
                    count += 1
                    onTile(Tile(url: url, geometricError: node.geometricError, distance: distance))
                }
            } else if !children.isEmpty {
                // No renderable content at this level; keep descending.
                frontier.append(contentsOf: children.map {
                    ($0, horizontalDistance(of: $0.boundingVolume))
                })
            }
        }
        return count
    }

    /// Downloads one tile GLB to a temporary file and returns its URL
    /// (GLTFKit2 loads from file URLs).
    func download(_ tile: Tile) async throws -> URL {
        let (data, response) = try await session.data(from: tile.url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StreamError.httpError(http.statusCode, tile.url)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hq-tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(UUID().uuidString + ".glb")
        try data.write(to: file)
        return file
    }

    // MARK: Requests

    private func fetch(uri: String, sessionToken: inout String?) async throws -> Data {
        guard let url = requestURL(uri: uri, sessionToken: sessionToken) else {
            throw StreamError.badRootResponse
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StreamError.httpError(http.statusCode, url)
        }
        // Remember the session token Google mints in child URIs so we can
        // attach it to any URI that arrives without one.
        if sessionToken == nil,
           let text = String(data: data, encoding: .utf8),
           let range = text.range(of: "session=") {
            let tail = text[range.upperBound...]
            sessionToken = String(tail.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }))
        }
        return data
    }

    private func requestURL(uri: String, sessionToken: String?) -> URL? {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(""), resolvingAgainstBaseURL: false),
              let uriComponents = URLComponents(string: uri) else { return nil }
        components.path = uriComponents.path
        var items = uriComponents.queryItems ?? []
        if let token = sessionToken, !items.contains(where: { $0.name == "session" }) {
            items.append(URLQueryItem(name: "session", value: token))
        }
        items.append(URLQueryItem(name: "key", value: apiKey))
        components.queryItems = items
        return components.url
    }

    // MARK: Bounding-volume tests

    /// Conservative horizontal distance (m) from the park anchor to the
    /// node's bounding volume (0 when the volume covers the anchor). Drives
    /// the distance-based LOD, so erring small just means extra detail.
    private func horizontalDistance(of volume: Node.BoundingVolume) -> Double {
        if let region = volume.region, region.count >= 6 {
            let center = HQGeo.parkPosition(
                latitude: (region[1] + region[3]) / 2,
                longitude: (region[0] + region[2]) / 2,
                height: 0
            )
            let corner = HQGeo.parkPosition(latitude: region[3], longitude: region[2], height: 0)
            let halfDiagonal = simd_length(SIMD2(corner.x - center.x, corner.z - center.z))
            return max(0, simd_length(SIMD2(center.x, center.z)) - halfDiagonal)
        }
        if let box = volume.box, box.count >= 12 {
            let center = SIMD3(box[0], box[1], box[2])
            let radius = simd_length(SIMD3(box[3], box[4], box[5]))
                + simd_length(SIMD3(box[6], box[7], box[8]))
                + simd_length(SIMD3(box[9], box[10], box[11]))
            return max(0, simd_distance(center, HQGeo.anchorECEF) - radius)
        }
        return 0
    }

    private func intersectsPark(_ volume: Node.BoundingVolume) -> Bool {
        if let region = volume.region, region.count >= 6 {
            // Region corners → park frame; test horizontal distance to anchor.
            let lats = [region[1], region[3]], lons = [region[0], region[2]]
            var minX = Double.infinity, maxX = -Double.infinity
            var minZ = Double.infinity, maxZ = -Double.infinity
            for lat in lats {
                for lon in lons {
                    let p = HQGeo.parkPosition(latitude: lat, longitude: lon, height: 0)
                    minX = min(minX, p.x); maxX = max(maxX, p.x)
                    minZ = min(minZ, p.z); maxZ = max(maxZ, p.z)
                }
            }
            let r = HQGeo.tileRadius
            return maxX >= -r && minX <= r && maxZ >= -r && minZ <= r
        }
        if let box = volume.box, box.count >= 12 {
            // Conservative sphere test in ECEF: centre distance vs box radius
            // + park radius.
            let center = SIMD3(box[0], box[1], box[2])
            let radius = simd_length(SIMD3(box[3], box[4], box[5]))
                + simd_length(SIMD3(box[6], box[7], box[8]))
                + simd_length(SIMD3(box[9], box[10], box[11]))
            return simd_distance(center, HQGeo.anchorECEF) <= radius + HQGeo.tileRadius
        }
        return true // Unknown volume type: be permissive.
    }
}

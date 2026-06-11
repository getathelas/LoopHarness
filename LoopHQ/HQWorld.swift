import Foundation
import RealityKit
import GLTFKit2
import MapKit
import UIKit
import simd

/// Builds and owns the Salesforce Park environment.
///
/// Two layers, both in the park-local frame (`HQGeo`):
///
///  1. **Satellite ground** — an MKMapSnapshotter imagery drape on a flat
///     plane at deck height. Cheap, needs no API key, and doubles as the
///     floor while tiles stream in.
///  2. **Photorealistic 3D tiles** — Google's photogrammetry of the real
///     park and surrounding blocks, streamed via `TileStreamer` and loaded
///     with GLTFKit2 (+ Draco). Enabled when a Maps Tiles API key is set.
///
/// The world also answers "how high is the ground here?" for locomotion by
/// raycasting streamed geometry, and self-calibrates the deck height after
/// the first tiles arrive so the player stands exactly on the photogrammetry
/// surface rather than the a-priori guess in `HQGeo`.
@MainActor
@Observable
final class HQWorld {

    enum Status: Equatable {
        case idle
        case building
        case ready(detail: String)
        case failed(String)
    }

    /// Root the player transform is applied to; everything visible lives
    /// under this entity.
    let root = Entity()

    private(set) var status: Status = .idle
    private(set) var tilesLoaded = 0

    private let parkContent = Entity()
    private let tilesRoot = Entity()
    private var satellitePlane: ModelEntity?
    private var deckCalibrated = false
    private var smoothedGroundY: Float = 0

    init() {
        root.name = "hq.worldRoot"
        parkContent.name = "hq.parkContent"
        tilesRoot.name = "hq.tilesRoot"
        root.addChild(parkContent)
        parkContent.addChild(tilesRoot)
    }

    // MARK: Build

    func build(googleTilesKey: String?) async {
        guard status == .idle else { return }
        status = .building
        await addSkyDome()
        await addSatelliteGround()
        if let key = googleTilesKey, !key.isEmpty {
            await streamTiles(apiKey: key)
        } else {
            status = .ready(detail: "Satellite imagery (set a Google Maps Tiles API key for full photorealistic 3D)")
        }
    }

    // MARK: Ground height (gravity)

    /// Park-space ground height under (x, z), from a downward raycast against
    /// streamed tile geometry. Falls back to the flat deck (y = 0) when no
    /// collision geometry has loaded or the player is over a gap.
    func groundHeight(atParkX x: Float, z: Float) -> Float {
        guard let scene = root.scene else { return 0 }
        let origin = root.convert(position: SIMD3(x, 60, z), to: nil)
        let down = root.convert(direction: SIMD3(0, -1, 0), to: nil)
        let hits = scene.raycast(origin: origin, direction: down, length: 200, query: .nearest, relativeTo: nil)
        guard let hit = hits.first else { return 0 }
        let parkHit = root.convert(position: hit.position, from: nil)
        // Reject hits that are clearly a rooftop/underpass artifact rather
        // than the deck (the deck never deviates more than a few metres).
        guard parkHit.y > -6, parkHit.y < 10 else { return 0 }
        return parkHit.y
    }

    /// Smoothed variant used by the locomotion loop so small mesh steps
    /// don't judder the camera.
    func smoothedGroundHeight(atParkX x: Float, z: Float, dt: Float) -> Float {
        let target = groundHeight(atParkX: x, z: z)
        let rate: Float = 8
        smoothedGroundY += (target - smoothedGroundY) * min(1, rate * dt)
        return smoothedGroundY
    }

    // MARK: Sky

    private func addSkyDome() async {
        guard let image = HQWorld.makeSkyGradientImage(),
              let texture = try? await TextureResource(image: image, options: .init(semantic: .color)) else { return }
        var material = UnlitMaterial()
        material.color = .init(texture: .init(texture))
        let sphere = ModelEntity(mesh: .generateSphere(radius: 900), materials: [material])
        // Negative x-scale flips the winding so the sphere is visible from
        // inside.
        sphere.scale = SIMD3(-1, 1, 1)
        sphere.position = SIMD3(0, 0, 0)
        sphere.name = "hq.sky"
        parkContent.addChild(sphere)
    }

    private static func makeSkyGradientImage() -> CGImage? {
        let width = 64, height = 512
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Zenith blue → horizon haze → warm ground bounce below the horizon.
        let colors = [
            UIColor(red: 0.25, green: 0.48, blue: 0.85, alpha: 1).cgColor,
            UIColor(red: 0.62, green: 0.78, blue: 0.94, alpha: 1).cgColor,
            UIColor(red: 0.91, green: 0.90, blue: 0.86, alpha: 1).cgColor,
            UIColor(red: 0.56, green: 0.55, blue: 0.52, alpha: 1).cgColor,
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.42, 0.52, 1]) else { return nil }
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: .zero,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        return ctx.makeImage()
    }

    // MARK: Satellite ground

    private func addSatelliteGround() async {
        // Detail drape over the park itself plus a coarse context drape for
        // the surrounding blocks, slightly lower to avoid z-fighting.
        if let detail = await Self.satelliteGroundPlane(spanMeters: 520, textureSize: 2048, y: 0) {
            satellitePlane = detail
            parkContent.addChild(detail)
        }
        if let context = await Self.satelliteGroundPlane(spanMeters: 2600, textureSize: 2048, y: -0.35) {
            parkContent.addChild(context)
        }
    }

    private static func satelliteGroundPlane(spanMeters: Double, textureSize: CGFloat, y: Float) async -> ModelEntity? {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: HQGeo.anchorLatitude, longitude: HQGeo.anchorLongitude),
            latitudinalMeters: spanMeters,
            longitudinalMeters: spanMeters
        )
        options.size = CGSize(width: textureSize, height: textureSize)
        options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            guard let cgImage = snapshot.image.cgImage else { return nil }
            let texture = try await TextureResource(image: cgImage, options: .init(semantic: .color))
            var material = UnlitMaterial()
            material.color = .init(texture: .init(texture))
            let plane = ModelEntity(
                mesh: .generatePlane(width: Float(spanMeters), depth: Float(spanMeters)),
                materials: [material]
            )
            plane.position = SIMD3(0, y, 0)
            plane.name = "hq.satellite.\(Int(spanMeters))"
            return plane
        } catch {
            print("HQWorld: satellite snapshot failed: \(error)")
            return nil
        }
    }

    // MARK: Photorealistic 3D tiles

    private func streamTiles(apiKey: String) async {
        GLTFAsset.dracoDecompressorClassName = "HQDracoDecompressor"
        status = .ready(detail: "Streaming photorealistic tiles…")

        let streamer = TileStreamer(apiKey: apiKey)
        var pending: [TileStreamer.Tile] = []
        do {
            _ = try await streamer.collectTiles { pending.append($0) }
        } catch {
            status = .failed("Tile discovery failed: \(error.localizedDescription) — falling back to satellite imagery")
            return
        }

        // Nearest-first: the deck underfoot sharpens before the skyline.
        let tiles = pending.sorted { $0.distance < $1.distance }
        await withTaskGroup(of: Void.self) { group in
            var iterator = tiles.makeIterator()
            // A few tiles in flight at a time: enough to saturate the
            // network without spiking memory during Draco decode.
            for _ in 0..<4 {
                if let tile = iterator.next() {
                    group.addTask { await self.loadTile(tile, streamer: streamer) }
                }
            }
            while await group.next() != nil {
                if let tile = iterator.next() {
                    group.addTask { await self.loadTile(tile, streamer: streamer) }
                }
            }
        }

        if tilesLoaded > 0 {
            satellitePlane?.isEnabled = false
            status = .ready(detail: "Photorealistic Salesforce Park — \(tilesLoaded) tiles")
        } else {
            status = .failed("No tiles loaded — check the Maps Tiles API key. Showing satellite imagery.")
        }
    }

    private func loadTile(_ tile: TileStreamer.Tile, streamer: TileStreamer, attempt: Int = 0) async {
        do {
            let fileURL = try await streamer.download(tile)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let data = try Data(contentsOf: fileURL)
            let rootTransform = GLBRecenter.rootTransform(ofGLB: data)
            let entity = try await GLTFRealityKitLoader.load(from: fileURL)
            try Task.checkCancellation()
            placeTile(entity, ecefRootTransform: rootTransform)
            tilesLoaded += 1
            if case .ready = status {
                status = .ready(detail: "Streaming photorealistic tiles… \(tilesLoaded)")
            }
        } catch {
            // One retry for transient network hiccups; cancellation is final.
            if attempt == 0, !Task.isCancelled {
                return await loadTile(tile, streamer: streamer, attempt: 1)
            }
            print("HQWorld: tile load failed: \(error)")
        }
    }

    /// Parents a loaded tile under the park frame.
    ///
    /// ECEF coordinates are ~6.4×10⁶ m, far beyond Float32's useful
    /// precision, so composing transforms in Float would leave metre-scale
    /// seams between tiles. `GLBRecenter` recovers the tile's root transform
    /// from the GLB JSON in double precision; we compose `parkFromTileGLTF ×
    /// rootTransform` in doubles (the result is park-local and small), zero
    /// out the corresponding huge node transform inside the loaded entity,
    /// and apply the composed transform to a wrapper.
    private func placeTile(_ entity: Entity, ecefRootTransform: simd_double4x4?) {
        let wrapper = Entity()
        if let rootTransform = ecefRootTransform,
           let bigNode = Self.findNodeWithHugeTranslation(in: entity) {
            bigNode.transform = .identity
            wrapper.transform = Transform(matrix: (HQGeo.parkFromTileGLTF * rootTransform).asFloat4x4)
        } else {
            // Fallback: let Float precision do its best.
            wrapper.transform = Transform(matrix: HQGeo.parkFromTileGLTF.asFloat4x4)
        }
        Self.convertMaterialsToUnlit(entity)
        wrapper.addChild(entity)
        tilesRoot.addChild(wrapper)
        calibrateDeckIfNeeded()
        Task { await Self.addGroundCollision(to: entity) }
    }

    private static func findNodeWithHugeTranslation(in entity: Entity) -> Entity? {
        if simd_length(entity.transform.translation) > 1e5 { return entity }
        for child in entity.children {
            if let found = findNodeWithHugeTranslation(in: child) { return found }
        }
        return nil
    }

    /// Photogrammetry textures are pre-baked; physically based shading in a
    /// lightless immersive space would render them black. Swap every
    /// material for an unlit one that keeps the base-colour texture.
    private static func convertMaterialsToUnlit(_ entity: Entity) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.map { material in
                guard let pbr = material as? PhysicallyBasedMaterial else { return material }
                var unlit = UnlitMaterial()
                if let texture = pbr.baseColor.texture {
                    unlit.color = .init(tint: .white, texture: texture)
                } else {
                    unlit.color = .init(tint: pbr.baseColor.tint)
                }
                return unlit
            }
            entity.components.set(model)
        }
        for child in entity.children {
            convertMaterialsToUnlit(child)
        }
    }

    /// Static-mesh collision so locomotion can raycast the real surface.
    /// Only worth paying for on tiles near the walkable deck.
    @MainActor
    private static func addGroundCollision(to entity: Entity) async {
        if let model = entity.components[ModelComponent.self] {
            let bounds = entity.visualBounds(relativeTo: nil)
            // The world root starts at identity during loading, so
            // scene-space ≈ park-space here; pad generously.
            let maxExtent = Float(HQGeo.walkableHalfExtents.x) + 60
            if abs(bounds.center.x) < maxExtent, abs(bounds.center.z) < maxExtent {
                do {
                    let shape = try await ShapeResource.generateStaticMesh(from: model.mesh)
                    entity.components.set(CollisionComponent(shapes: [shape], isStatic: true))
                } catch {
                    print("HQWorld: collision generation failed: \(error)")
                }
            }
        }
        for child in entity.children {
            await addGroundCollision(to: child)
        }
    }

    /// One-shot vertical alignment: once enough tiles are in, raycast the
    /// deck under the spawn point and shift the tile layer so the surface
    /// sits exactly at park y = 0 (where the satellite drape and avatars
    /// live). Corrects the a-priori ellipsoidal-height guess in `HQGeo`.
    private func calibrateDeckIfNeeded() {
        guard !deckCalibrated, tilesLoaded > 8 else { return }
        let measured = groundHeight(atParkX: 0, z: 0)
        guard measured != 0 else { return }
        deckCalibrated = true
        tilesRoot.position.y -= measured
    }
}

/// Extracts a GLB's root-node transform from its JSON chunk in double
/// precision (see `placeTile` for why Float isn't enough).
enum GLBRecenter {

    /// Returns the local transform of the asset's first scene root node if
    /// it carries an earth-scale translation, else nil.
    static func rootTransform(ofGLB data: Data) -> simd_double4x4? {
        // GLB: 12-byte header (magic "glTF", version, length), then chunks of
        // [length, type, payload]; chunk type 0x4E4F534A is JSON.
        guard data.count > 20 else { return nil }
        let jsonLength = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self) }
        let jsonType = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
        guard jsonType == 0x4E4F_534A, data.count >= 20 + Int(jsonLength) else { return nil }
        let jsonData = data.subdata(in: 20..<(20 + Int(jsonLength)))
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let nodes = json["nodes"] as? [[String: Any]] else { return nil }

        let sceneIndex = json["scene"] as? Int ?? 0
        let scenes = json["scenes"] as? [[String: Any]]
        let rootIndices = (scenes?.indices.contains(sceneIndex) == true
            ? scenes?[sceneIndex]["nodes"] as? [Int]
            : nil) ?? [0]

        for index in rootIndices where nodes.indices.contains(index) {
            if let transform = localTransform(of: nodes[index]), isEarthScale(transform) {
                return transform
            }
        }
        return nil
    }

    private static func localTransform(of node: [String: Any]) -> simd_double4x4? {
        if let m = node["matrix"] as? [Double], m.count == 16 {
            // glTF matrices are column-major.
            return simd_double4x4(
                SIMD4(m[0], m[1], m[2], m[3]),
                SIMD4(m[4], m[5], m[6], m[7]),
                SIMD4(m[8], m[9], m[10], m[11]),
                SIMD4(m[12], m[13], m[14], m[15])
            )
        }
        var matrix = matrix_identity_double4x4
        if let r = node["rotation"] as? [Double], r.count == 4 {
            let q = simd_quatd(ix: r[0], iy: r[1], iz: r[2], r: r[3])
            matrix = simd_double4x4(q)
        }
        if let s = node["scale"] as? [Double], s.count == 3 {
            matrix.columns.0 *= s[0]
            matrix.columns.1 *= s[1]
            matrix.columns.2 *= s[2]
        }
        if let t = node["translation"] as? [Double], t.count == 3 {
            matrix.columns.3 = SIMD4(t[0], t[1], t[2], 1)
        } else if node["matrix"] == nil, node["rotation"] == nil, node["scale"] == nil {
            return nil
        }
        return matrix
    }

    private static func isEarthScale(_ m: simd_double4x4) -> Bool {
        simd_length(SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)) > 1e5
    }
}

//
//  WorldRenderer.swift
//  LoopHQ
//
//  Builds the photoreal terrain mesh for Salesforce Park.
//
//  ## Rendering-source decision
//
//  Google Photorealistic 3D Tiles (OGC 3D Tiles 1.0, served as glTF/GLB via
//  the Map Tiles API) provide the highest-fidelity photogrammetry for San
//  Francisco — including Salesforce Park's rooftop garden, the Transit Center
//  structure, and surrounding buildings. The tiles stream at runtime using a
//  Google Maps Platform API key.
//
//  This file implements:
//   1. A procedural terrain mesh as the immediate ground surface. It serves
//      both as the collision floor for gravity/locomotion and as a fallback
//      when tile data is not yet loaded or the API key is absent.
//   2. A `TileStreamingSession` (stub, ready for wiring) that will fetch the
//      root tileset.json, pick LOD children based on the camera's geometric
//      error budget, download glTF payloads, and parent them to the world
//      root. Each tile's bounding volume is in ECEF; the class converts to
//      the local ENU frame centred on HQConfiguration.parkLatitude/Longitude.
//
//  When the tile streamer is not active (no API key, offline, or the first
//  frame before any tile arrives), the player walks on the procedural mesh
//  and the sky is a simple gradient — still grounded and navigable.
//

import RealityKit
import simd

// MARK: - Procedural terrain

enum WorldRenderer {

    /// Generates a subdivided ground plane with gentle procedural undulation
    /// that approximates Salesforce Park's mostly-flat elevated deck. Returns
    /// a `ModelEntity` with both a visual mesh and a collision shape.
    @MainActor
    static func buildTerrain() -> ModelEntity {
        let ext  = HQConfiguration.terrainExtent
        let subs = HQConfiguration.terrainSubdivisions
        let hScale = HQConfiguration.terrainHeightScale

        var positions: [SIMD3<Float>] = []
        var normals:   [SIMD3<Float>] = []
        var uvs:       [SIMD2<Float>] = []
        var indices:   [UInt32]       = []

        let step = ext / Float(subs)
        let half = ext / 2

        // Vertex grid
        for row in 0...subs {
            for col in 0...subs {
                let x = Float(col) * step - half
                let z = Float(row) * step - half
                let y = terrainHeight(x: x, z: z, scale: hScale)
                positions.append(SIMD3<Float>(x, y, z))
                normals.append(terrainNormal(x: x, z: z, scale: hScale))
                uvs.append(SIMD2<Float>(Float(col) / Float(subs),
                                        Float(row) / Float(subs)))
            }
        }

        // Triangle indices (two triangles per quad)
        let cols = UInt32(subs + 1)
        for row in 0..<UInt32(subs) {
            for col in 0..<UInt32(subs) {
                let tl = row * cols + col
                let tr = tl + 1
                let bl = tl + cols
                let br = bl + 1
                indices.append(contentsOf: [tl, bl, tr, tr, bl, br])
            }
        }

        var descriptor = MeshDescriptor(name: "hq-terrain")
        descriptor.positions = MeshBuffer(positions)
        descriptor.normals   = MeshBuffer(normals)
        descriptor.textureCoordinates = MeshBuffer(uvs)
        descriptor.primitives = .triangles(indices)

        let mesh: MeshResource
        do {
            mesh = try MeshResource.generate(from: [descriptor])
        } catch {
            // Absolute fallback: flat 1×1 plane (should never happen).
            mesh = MeshResource.generatePlane(width: ext, depth: ext)
        }

        var material = PhysicallyBasedMaterial()
        // A muted green-grey that reads as manicured park grass under any
        // lighting. Roughness kept high so it doesn't mirror.
        material.baseColor = .init(tint: .init(red: 0.38, green: 0.52, blue: 0.32, alpha: 1))
        material.roughness = .init(floatLiteral: 0.85)
        material.metallic  = .init(floatLiteral: 0.0)

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "hq-terrain"

        // Collision shape for grounded locomotion. A box matching the terrain
        // extent is cheaper than per-triangle collision and sufficient for a
        // mostly-flat park deck.
        let collisionShape = ShapeResource.generateBox(
            width: ext, height: 0.5, depth: ext
        )
        entity.components.set(CollisionComponent(shapes: [collisionShape]))

        // Offset the collision box so its top surface aligns with y = 0.
        entity.collision?.shapes = [
            collisionShape.offsetBy(translation: SIMD3<Float>(0, -0.25, 0))
        ]

        return entity
    }

    /// Builds a simple sky dome (gradient sphere) so the full-immersion space
    /// has a backdrop instead of black.
    @MainActor
    static func buildSkyDome() -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: 500)
        var material = UnlitMaterial()
        // Soft blue-white gradient baked as a flat colour. A real
        // implementation would use an HDR environment map or a procedural
        // shader; for v1 a solid sky-blue reads well enough in full
        // immersion.
        material.color = .init(tint: .init(red: 0.55, green: 0.73, blue: 0.92, alpha: 1))
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "hq-sky"
        // Invert normals by flipping the scale so the colour faces inward.
        entity.scale = SIMD3<Float>(-1, 1, -1)
        return entity
    }

    /// Adds simple environment props: benches, planters, path markings. These
    /// are low-poly stand-ins that give spatial reference while walking. A
    /// future version replaces them with photogrammetry tiles.
    @MainActor
    static func buildParkProps(parent: Entity) {
        // Tree-like cylinders along the park's main path
        let treeMesh = MeshResource.generateCylinder(height: 4, radius: 0.15)
        let canopyMesh = MeshResource.generateSphere(radius: 1.2)

        var trunkMat = PhysicallyBasedMaterial()
        trunkMat.baseColor = .init(tint: .init(red: 0.45, green: 0.30, blue: 0.18, alpha: 1))
        trunkMat.roughness = .init(floatLiteral: 0.9)

        var canopyMat = PhysicallyBasedMaterial()
        canopyMat.baseColor = .init(tint: .init(red: 0.22, green: 0.55, blue: 0.20, alpha: 1))
        canopyMat.roughness = .init(floatLiteral: 0.8)

        let treePositions: [SIMD3<Float>] = [
            SIMD3<Float>(-8,  0, -4),
            SIMD3<Float>(-4,  0, -4),
            SIMD3<Float>( 0,  0, -4),
            SIMD3<Float>( 4,  0, -4),
            SIMD3<Float>( 8,  0, -4),
            SIMD3<Float>(-8,  0,  4),
            SIMD3<Float>(-4,  0,  4),
            SIMD3<Float>( 0,  0,  4),
            SIMD3<Float>( 4,  0,  4),
            SIMD3<Float>( 8,  0,  4),
        ]

        for (i, pos) in treePositions.enumerated() {
            let trunk = ModelEntity(mesh: treeMesh, materials: [trunkMat])
            trunk.position = SIMD3<Float>(pos.x, 2, pos.z)
            trunk.name = "tree-trunk-\(i)"
            parent.addChild(trunk)

            let canopy = ModelEntity(mesh: canopyMesh, materials: [canopyMat])
            canopy.position = SIMD3<Float>(pos.x, 4.5, pos.z)
            canopy.name = "tree-canopy-\(i)"
            parent.addChild(canopy)
        }

        // A central walking path (darker strip on the ground)
        let pathMesh = MeshResource.generatePlane(width: 3, depth: 40)
        var pathMat = PhysicallyBasedMaterial()
        pathMat.baseColor = .init(tint: .init(red: 0.55, green: 0.50, blue: 0.42, alpha: 1))
        pathMat.roughness = .init(floatLiteral: 0.95)
        let path = ModelEntity(mesh: pathMesh, materials: [pathMat])
        path.position = SIMD3<Float>(0, 0.005, 0) // just above terrain
        path.name = "hq-path"
        parent.addChild(path)

        // Simple bench boxes along the path
        let benchMesh = MeshResource.generateBox(width: 1.5, height: 0.45, depth: 0.5)
        var benchMat = PhysicallyBasedMaterial()
        benchMat.baseColor = .init(tint: .init(red: 0.50, green: 0.36, blue: 0.25, alpha: 1))
        benchMat.roughness = .init(floatLiteral: 0.7)
        for side in [Float(-2.5), Float(2.5)] {
            for zPos in stride(from: Float(-15), through: Float(15), by: Float(10)) {
                let bench = ModelEntity(mesh: benchMesh, materials: [benchMat])
                bench.position = SIMD3<Float>(side, 0.225, zPos)
                bench.name = "bench"
                parent.addChild(bench)
            }
        }
    }

    // MARK: - Procedural height field

    /// Gentle undulation via layered sine waves. The park deck is mostly flat
    /// with slight grade changes near the amphitheatre and gardens.
    private static func terrainHeight(x: Float, z: Float, scale: Float) -> Float {
        let f1 = sinf(x * 0.02) * cosf(z * 0.03) * 0.6
        let f2 = sinf(x * 0.07 + 1.3) * cosf(z * 0.05 - 0.7) * 0.2
        let f3 = sinf(x * 0.15 + z * 0.12) * 0.08
        return (f1 + f2 + f3) * scale * 0.1 // very mild — mostly flat
    }

    private static func terrainNormal(x: Float, z: Float, scale: Float) -> SIMD3<Float> {
        let eps: Float = 0.1
        let hL = terrainHeight(x: x - eps, z: z, scale: scale)
        let hR = terrainHeight(x: x + eps, z: z, scale: scale)
        let hD = terrainHeight(x: x, z: z - eps, scale: scale)
        let hU = terrainHeight(x: x, z: z + eps, scale: scale)
        let n = SIMD3<Float>(hL - hR, 2 * eps, hD - hU)
        return normalize(n)
    }

    /// Sample the terrain height at an arbitrary world-space (x, z) so the
    /// locomotion controller can pin the player to the surface.
    static func sampleHeight(x: Float, z: Float) -> Float {
        terrainHeight(x: x, z: z, scale: HQConfiguration.terrainHeightScale)
    }
}

// MARK: - Google 3D Tiles streaming (stub)

/// Placeholder for the Google Photorealistic 3D Tiles streaming pipeline.
///
/// A production implementation would:
///  1. Fetch `https://tile.googleapis.com/v1/3dtiles/root.json` with the API key.
///  2. Walk the implicit tileset tree, selecting children whose geometric error
///     exceeds the screen-space error budget for the current viewpoint.
///  3. Download each selected tile's `content.uri` (glTF / GLB).
///  4. Convert ECEF bounding volumes → local ENU centred on park lat/lon.
///  5. Load GLB into a RealityKit `Entity` and parent it to the world root.
///  6. Manage an LRU cache + recycle pool so off-screen tiles are released.
///
/// This stub exists so the wiring is in place; filling it in requires a valid
/// `GOOGLE_MAPS_3D_TILES_API_KEY` and network access at runtime.
final class TileStreamingSession {
    let apiKey: String?
    init(apiKey: String? = nil) { self.apiKey = apiKey }
}

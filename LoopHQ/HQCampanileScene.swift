import Foundation
import simd

/// Authors the voxel Campanile world: a floating circular plaza platform
/// with UC Berkeley's Campanile (Sather Tower) at its centre, ringed by
/// stylised trees, hedges, benches and lamps. Everything is deterministic —
/// the same world is generated on every device, which is what keeps
/// SharePlay participants standing on the same blocks.
///
/// Scale is true-ish to life: the tower is ~95 m tall on a 42 m-radius
/// platform (the spec's "tower + ~50 m radius"), in 0.5 m voxels.
enum HQCampanileScene {

    /// Geometry radius of the platform disc.
    static let platformRadius: Float = 42
    /// Locomotion clamp, comfortably inside the rim balustrade.
    static let walkableRadius: Float = 39.5
    /// Player spawn: on the main path south of the tower, facing it.
    static let spawnPosition = SIMD3<Float>(0, 0, 26)

    static let voxelSize: Float = 0.5

    // MARK: World grid

    static func build() -> HQVoxelGrid {
        // x/z span ±43 m, y spans −8 (platform underside) … 96 (above the
        // tower's gold lantern).
        var grid = HQVoxelGrid(
            sizeX: 172, sizeY: 208, sizeZ: 172,
            voxelSize: voxelSize,
            origin: SIMD3(-43, -8, -43)
        )
        buildPlatform(&grid)
        buildTower(&grid)
        buildTrees(&grid)
        buildFurniture(&grid)
        return grid
    }

    // MARK: Platform

    /// The plaza disc: checkerboard stone around the tower, cross paths and
    /// a promenade ring through lawn quadrants, a rim balustrade, and a
    /// tapering rocky underside so the platform reads as a floating island.
    private static func buildPlatform(_ grid: inout HQVoxelGrid) {
        let surfaceRow = grid.yIndex(-0.25)   // top voxel of the slab, [-0.5, 0)
        let slabBottomRow = grid.yIndex(-2.75)

        for ix in 0..<grid.sizeX {
            for iz in 0..<grid.sizeZ {
                let center = grid.columnCenter(ix, iz)
                let radius = simd_length(center)
                guard radius <= platformRadius else { continue }

                let x = center.x, z = center.y
                let checker = (Int((x / 2).rounded(.down)) + Int((z / 2).rounded(.down))) & 1 == 0
                let noise = hash(ix, iz)

                let surface: HQBlock
                if radius < 12 {
                    surface = checker ? .plazaLight : .plazaDark
                } else if abs(x) < 3.5 || abs(z) < 3.5 {
                    surface = checker ? .plazaLight : .path
                } else if radius > 20.5, radius < 24.5 {
                    surface = checker ? .path : .plazaDark
                } else {
                    surface = noise % 5 == 0 ? .grassDark : .grass
                }

                // Slab: surface tile, two rows of dirt, bedrock to −3 m.
                grid.set(ix, surfaceRow, iz, surface)
                grid.set(ix, surfaceRow - 1, iz, .dirt)
                grid.set(ix, surfaceRow - 2, iz, .dirt)
                for row in slabBottomRow..<(surfaceRow - 2) {
                    grid.set(ix, row, iz, .bedrock)
                }

                // Tapering underside: radius shrinks ~2.8 m per metre of
                // depth, down to the grid floor at −8 m.
                var row = slabBottomRow - 1
                while row >= 0 {
                    let rowCenterY: Float = grid.origin.y + (Float(row) + 0.5) * grid.voxelSize
                    let depth: Float = -2.75 - rowCenterY
                    guard radius <= platformRadius - depth * 2.8 else { break }
                    grid.set(ix, row, iz, noise % 4 == 0 ? .dirt : .bedrock)
                    row -= 1
                }

                // Rim balustrade: a metre-high wall at the platform edge.
                if radius > 40.5, radius <= 41.5 {
                    grid.set(ix, surfaceRow + 1, iz, .granite)
                    grid.set(ix, surfaceRow + 2, iz, .granite)
                }
            }
        }
    }

    // MARK: Tower

    /// The Campanile, stylised: stepped pedestal, granite shaft with paired
    /// window slits, clock faces, an arched bell loggia over a dark core,
    /// and a stepped pyramid roof with a gold lantern. ~95 m to the tip.
    private static func buildTower(_ grid: inout HQVoxelGrid) {
        func box(_ halfExtent: Float, _ y0: Float, _ y1: Float, _ block: HQBlock) {
            grid.fill(-halfExtent, halfExtent, y0, y1, -halfExtent, halfExtent, block)
        }

        // Pedestal: three walkable 0.5 m steps up to a 2.5 m base block.
        box(9.0, 0.0, 0.5, .granite)
        box(8.5, 0.5, 1.0, .granite)
        box(8.0, 1.0, 1.5, .granite)
        box(6.5, 1.5, 4.0, .graniteShade)

        // Shaft with corner accent columns.
        box(5.0, 4, 58, .granite)
        for sx: Float in [-1, 1] {
            for sz: Float in [-1, 1] {
                grid.fill(min(4 * sx, 5 * sx), max(4 * sx, 5 * sx), 4, 58,
                          min(4 * sz, 5 * sz), max(4 * sz, 5 * sz), .graniteShade)
            }
        }

        // Paired window slits on each face, in segments separated by
        // granite bands.
        for segment in 0..<6 {
            let y0 = 6 + Float(segment) * 8
            let y1 = y0 + 6
            for offset: Float in [-2, 1] {
                let u0 = offset, u1 = offset + 1
                grid.fill(u0, u1, y0, y1, 4.5, 5.0, .windowDark)    // +z face
                grid.fill(u0, u1, y0, y1, -5.0, -4.5, .windowDark)  // −z face
                grid.fill(4.5, 5.0, y0, y1, u0, u1, .windowDark)    // +x face
                grid.fill(-5.0, -4.5, y0, y1, u0, u1, .windowDark)  // −x face
            }
        }

        // Belt cornice under the clock stage.
        box(5.75, 58, 59.5, .graniteShade)

        // Clock stage: a white dial with simple dark hands on each face.
        box(5.0, 59.5, 67, .granite)
        paintAllFaces(&grid, halfExtent: 5.0, u0: -2, u1: 2, y0: 61, y1: 65, block: .clockFace)
        paintAllFaces(&grid, halfExtent: 5.0, u0: -0.5, u1: 0, y0: 62.5, y1: 64.5, block: .windowDark)
        paintAllFaces(&grid, halfExtent: 5.0, u0: 0, u1: 1.5, y0: 62.5, y1: 63, block: .windowDark)

        // Bell loggia: granite shell, solid dark core, three arched
        // openings carved out of the shell on each face.
        box(5.0, 67, 77, .granite)
        box(4.5, 67, 77, .windowDark)
        for opening: (Float, Float) in [(-3.75, -2.25), (-0.75, 0.75), (2.25, 3.75)] {
            carveAllFaces(&grid, halfExtent: 5.0, u0: opening.0, u1: opening.1, y0: 68, y1: 74.5)
            carveAllFaces(&grid, halfExtent: 5.0, u0: opening.0 + 0.5, u1: opening.1 - 0.5, y0: 74.5, y1: 75)
        }

        // Observation cornice and parapet.
        box(6.25, 77, 78.5, .graniteShade)
        box(6.25, 78.5, 79.5, .granite)
        box(5.5, 78.5, 79.5, .air)

        // Stepped pyramid roof, then the gold lantern tip.
        var y: Float = 79.5
        while y < 93.5 {
            let t = (y - 79.5) / 14
            let halfExtent = ((5.5 + (0.5 - 5.5) * t) / voxelSize).rounded() * voxelSize
            box(max(halfExtent, 0.5), y, y + 0.5, .roof)
            y += 0.5
        }
        box(0.5, 93.5, 95, .gold)
    }

    /// Paints the outermost voxel layer on all four faces of a square tower
    /// stage; `u` is the in-face horizontal coordinate.
    private static func paintAllFaces(
        _ grid: inout HQVoxelGrid, halfExtent: Float,
        u0: Float, u1: Float, y0: Float, y1: Float, block: HQBlock
    ) {
        grid.fill(u0, u1, y0, y1, halfExtent - 0.5, halfExtent, block)
        grid.fill(u0, u1, y0, y1, -halfExtent, -halfExtent + 0.5, block)
        grid.fill(halfExtent - 0.5, halfExtent, y0, y1, u0, u1, block)
        grid.fill(-halfExtent, -halfExtent + 0.5, y0, y1, u0, u1, block)
    }

    private static func carveAllFaces(
        _ grid: inout HQVoxelGrid, halfExtent: Float,
        u0: Float, u1: Float, y0: Float, y1: Float
    ) {
        paintAllFaces(&grid, halfExtent: halfExtent, u0: u0, u1: u1, y0: y0, y1: y1, block: .air)
    }

    // MARK: Trees

    /// A ring of chunky voxel trees in the lawn quadrants. Deterministic
    /// seeded placement; spots over paths or near the spawn are skipped.
    private static func buildTrees(_ grid: inout HQVoxelGrid) {
        var rng = HQRandom(seed: 0xCA_B005E)
        let count = 18
        for i in 0..<count {
            let angle = (Float(i) + 0.4 * rng.unit()) * (2 * .pi / Float(count))
            let radius = 26 + rng.unit() * 11
            let x = (sin(angle) * radius * 2).rounded() / 2
            let z = (cos(angle) * radius * 2).rounded() / 2
            // Keep paths, the promenade edges and the spawn view clear.
            if abs(x) < 5.5 || abs(z) < 5.5 { continue }
            if simd_length(SIMD2(x, z) - SIMD2(spawnPosition.x, spawnPosition.z)) < 7 { continue }

            let trunkHeight = 3.5 + (rng.unit() * 3).rounded() * 0.5
            grid.fill(x - 0.5, x + 0.5, 0, trunkHeight, z - 0.5, z + 0.5, .trunk)

            let canopyCenter = SIMD3(x, trunkHeight + 1.2, z)
            let rx = 2.2 + rng.unit()
            let ry = 1.8 + rng.unit() * 0.7
            let rz = 2.2 + rng.unit()
            let lightSeed = Int(rng.next() & 0xFFFF)

            let x0 = grid.xIndex(x - rx), x1 = grid.xIndex(x + rx)
            let y0 = grid.yIndex(canopyCenter.y - ry), y1 = grid.yIndex(canopyCenter.y + ry)
            let z0 = grid.zIndex(z - rz), z1 = grid.zIndex(z + rz)
            for ix in x0...x1 {
                for iy in y0...y1 {
                    for iz in z0...z1 {
                        let cell = grid.columnCenter(ix, iz)
                        let cy = grid.origin.y + (Float(iy) + 0.5) * grid.voxelSize
                        let d = SIMD3(cell.x - canopyCenter.x, cy - canopyCenter.y, cell.y - canopyCenter.z)
                        let e = (d.x * d.x) / (rx * rx) + (d.y * d.y) / (ry * ry) + (d.z * d.z) / (rz * rz)
                        guard e <= 1 else { continue }
                        let n = hash(ix &+ lightSeed, iz &+ iy)
                        if n % 9 == 0 { continue }  // ragged edges
                        if grid.block(ix, iy, iz) == 0 {
                            grid.set(ix, iy, iz, n % 3 == 0 ? .leavesLight : .leaves)
                        }
                    }
                }
            }
        }
    }

    // MARK: Furniture

    private static func buildFurniture(_ grid: inout HQVoxelGrid) {
        // Hedges flanking the cross paths.
        for side: Float in [-4.5, 3.5] {
            grid.fill(side, side + 1, 0, 1, 10, 19, .hedge)
            grid.fill(side, side + 1, 0, 1, -19, -10, .hedge)
            grid.fill(10, 19, 0, 1, side, side + 1, .hedge)
            grid.fill(-19, -10, 0, 1, side, side + 1, .hedge)
        }

        // Low planter benches on the plaza diagonals (sit-height, steppable).
        for bx: Float in [-13, 13] {
            for bz: Float in [-13, 13] {
                grid.fill(bx - 1, bx + 1, 0, 0.5, bz - 0.75, bz + 0.75, .bench)
            }
        }

        // Lamps where the promenade crosses the paths.
        let lampSpots: [(Float, Float)] = [
            (4.0, 22.0), (-4.5, 22.0), (4.0, -22.5), (-4.5, -22.5),
            (22.0, 4.0), (22.0, -4.5), (-22.5, 4.0), (-22.5, -4.5),
        ]
        for (px, pz) in lampSpots {
            grid.fill(px, px + 0.5, 0, 3, pz, pz + 0.5, .lampPost)
            grid.fill(px - 0.5, px + 1.0, 3, 3.5, pz - 0.5, pz + 1.0, .lampGlow)
            grid.fill(px, px + 0.5, 3.5, 4, pz, pz + 0.5, .lampPost)
        }
    }

    // MARK: Clouds

    /// Small blocky cloud grids (2 m voxels) instanced around and below the
    /// floating platform.
    static func cloudTemplates() -> [HQVoxelGrid] {
        var a = HQVoxelGrid(sizeX: 14, sizeY: 3, sizeZ: 8, voxelSize: 2, origin: SIMD3(-14, 0, -8))
        a.fill(-12, 4, 0, 2, -4, 2, .cloud)
        a.fill(-6, 12, 2, 4, -6, 0, .cloud)
        a.fill(-8, 8, 0, 2, 2, 6, .cloud)

        var b = HQVoxelGrid(sizeX: 8, sizeY: 2, sizeZ: 6, voxelSize: 2, origin: SIMD3(-8, 0, -6))
        b.fill(-6, 6, 0, 2, -4, 2, .cloud)
        b.fill(-2, 8, 2, 4, -2, 4, .cloud)

        var c = HQVoxelGrid(sizeX: 16, sizeY: 2, sizeZ: 5, voxelSize: 2, origin: SIMD3(-16, 0, -5))
        c.fill(-14, 14, 0, 2, -2, 2, .cloud)
        c.fill(-8, 2, 2, 4, -4, 0, .cloud)
        return [a, b, c]
    }

    /// (template index, bearing degrees, distance, height, yaw degrees, scale)
    static let cloudPlacements: [(Int, Float, Float, Float, Float, Float)] = [
        (0, 15, 110, 48, 20, 1.6),
        (1, 70, 90, 38, 95, 1.2),
        (2, 130, 130, 62, 140, 1.8),
        (0, 185, 100, 44, 200, 1.3),
        (1, 235, 120, 55, 250, 1.7),
        (2, 300, 95, 35, 310, 1.1),
        (1, 40, 80, -24, 60, 1.4),
        (0, 260, 105, -30, 280, 1.5),
    ]

    // MARK: Determinism helpers

    private static func hash(_ a: Int, _ b: Int) -> Int {
        var h = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64(b)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 31)) &* 0x94D0_49BB_1331_11EB
        return Int(truncatingIfNeeded: h ^ (h >> 29)) & Int.max
    }
}

/// SplitMix64 — tiny deterministic RNG so world generation never depends on
/// the system generator.
struct HQRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Float {
        Float(next() >> 40) * (1.0 / Float(1 << 24))
    }
}

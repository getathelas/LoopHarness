import Foundation
import RealityKit
import UIKit
import simd

/// The block palette for the Campanile world. Raw value 0 is reserved for
/// air; everything else maps to a flat colour that the mesher tints per face
/// direction (top bright, bottom dark) for the classic voxel look without
/// any runtime lighting.
enum HQBlock: UInt8, CaseIterable {
    case air = 0

    // Plaza & platform
    case plazaLight
    case plazaDark
    case path
    case grass
    case grassDark
    case dirt
    case bedrock

    // Tower
    case granite
    case graniteShade
    case windowDark
    case clockFace
    case roof
    case gold

    // Greenery & furniture
    case trunk
    case leaves
    case leavesLight
    case hedge
    case bench
    case lampPost
    case lampGlow

    // Sky
    case cloud

    /// Base colour before per-face shading.
    var color: SIMD3<Float> {
        switch self {
        case .air: return .zero
        case .plazaLight: return SIMD3(0.80, 0.78, 0.73)
        case .plazaDark: return SIMD3(0.70, 0.68, 0.63)
        case .path: return SIMD3(0.82, 0.75, 0.62)
        case .grass: return SIMD3(0.43, 0.66, 0.32)
        case .grassDark: return SIMD3(0.37, 0.59, 0.28)
        case .dirt: return SIMD3(0.50, 0.40, 0.30)
        case .bedrock: return SIMD3(0.44, 0.43, 0.42)
        case .granite: return SIMD3(0.86, 0.84, 0.78)
        case .graniteShade: return SIMD3(0.76, 0.74, 0.68)
        case .windowDark: return SIMD3(0.16, 0.18, 0.22)
        case .clockFace: return SIMD3(0.96, 0.95, 0.88)
        case .roof: return SIMD3(0.45, 0.62, 0.53)
        case .gold: return SIMD3(0.93, 0.77, 0.32)
        case .trunk: return SIMD3(0.43, 0.32, 0.21)
        case .leaves: return SIMD3(0.28, 0.52, 0.23)
        case .leavesLight: return SIMD3(0.35, 0.61, 0.27)
        case .hedge: return SIMD3(0.24, 0.44, 0.21)
        case .bench: return SIMD3(0.56, 0.41, 0.26)
        case .lampPost: return SIMD3(0.20, 0.20, 0.23)
        case .lampGlow: return SIMD3(1.00, 0.91, 0.62)
        case .cloud: return SIMD3(0.97, 0.97, 0.99)
        }
    }
}

/// A dense axis-aligned voxel grid in world metres. `origin` is the world
/// position of the minimum corner of voxel (0, 0, 0); every voxel is a cube
/// with edge `voxelSize`. Authoring happens through the metre-space `fill`
/// API (all scene dimensions are multiples of the voxel size, so ranges land
/// exactly on voxel boundaries).
struct HQVoxelGrid: Sendable {
    let sizeX: Int
    let sizeY: Int
    let sizeZ: Int
    let voxelSize: Float
    let origin: SIMD3<Float>
    private(set) var data: [UInt8]

    init(sizeX: Int, sizeY: Int, sizeZ: Int, voxelSize: Float, origin: SIMD3<Float>) {
        self.sizeX = sizeX
        self.sizeY = sizeY
        self.sizeZ = sizeZ
        self.voxelSize = voxelSize
        self.origin = origin
        data = [UInt8](repeating: 0, count: sizeX * sizeY * sizeZ)
    }

    @inline(__always)
    private func index(_ x: Int, _ y: Int, _ z: Int) -> Int {
        (y * sizeZ + z) * sizeX + x
    }

    /// Out-of-bounds reads are air, so the mesher and locomotion never need
    /// bounds branches at call sites.
    @inline(__always)
    func block(_ x: Int, _ y: Int, _ z: Int) -> UInt8 {
        guard x >= 0, x < sizeX, y >= 0, y < sizeY, z >= 0, z < sizeZ else { return 0 }
        return data[index(x, y, z)]
    }

    @inline(__always)
    mutating func set(_ x: Int, _ y: Int, _ z: Int, _ block: HQBlock) {
        guard x >= 0, x < sizeX, y >= 0, y < sizeY, z >= 0, z < sizeZ else { return }
        data[index(x, y, z)] = block.rawValue
    }

    var solidCount: Int {
        data.withUnsafeBufferPointer { buffer in
            var count = 0
            for value in buffer where value != 0 { count += 1 }
            return count
        }
    }

    // MARK: World ↔ grid

    @inline(__always) func xIndex(_ x: Float) -> Int { Int(((x - origin.x) / voxelSize).rounded(.down)) }
    @inline(__always) func yIndex(_ y: Float) -> Int { Int(((y - origin.y) / voxelSize).rounded(.down)) }
    @inline(__always) func zIndex(_ z: Float) -> Int { Int(((z - origin.z) / voxelSize).rounded(.down)) }

    /// World y of the top face of voxel row `row`.
    @inline(__always) func topOfRow(_ row: Int) -> Float { origin.y + Float(row + 1) * voxelSize }

    /// World-space centre of a voxel column's cell, for radial tests.
    @inline(__always) func columnCenter(_ x: Int, _ z: Int) -> SIMD2<Float> {
        SIMD2(origin.x + (Float(x) + 0.5) * voxelSize, origin.z + (Float(z) + 0.5) * voxelSize)
    }

    // MARK: Authoring

    /// Fills the half-open metre-space box [x0,x1) × [y0,y1) × [z0,z1).
    /// Pass `.air` to carve.
    mutating func fill(
        _ x0: Float, _ x1: Float,
        _ y0: Float, _ y1: Float,
        _ z0: Float, _ z1: Float,
        _ block: HQBlock
    ) {
        let ix0 = max(0, Int(((x0 - origin.x) / voxelSize).rounded()))
        let ix1 = min(sizeX, Int(((x1 - origin.x) / voxelSize).rounded()))
        let iy0 = max(0, Int(((y0 - origin.y) / voxelSize).rounded()))
        let iy1 = min(sizeY, Int(((y1 - origin.y) / voxelSize).rounded()))
        let iz0 = max(0, Int(((z0 - origin.z) / voxelSize).rounded()))
        let iz1 = min(sizeZ, Int(((z1 - origin.z) / voxelSize).rounded()))
        guard ix0 < ix1, iy0 < iy1, iz0 < iz1 else { return }
        for y in iy0..<iy1 {
            for z in iz0..<iz1 {
                let rowBase = (y * sizeZ + z) * sizeX
                for x in ix0..<ix1 {
                    data[rowBase + x] = block.rawValue
                }
            }
        }
    }
}

/// Greedy mesher: converts a voxel grid into a handful of flat-shaded mesh
/// surfaces, one per (block, face direction) pair that actually appears.
/// Coplanar same-block faces merge into maximal rectangles, so the whole
/// plaza floor is a few quads rather than tens of thousands.
enum HQVoxelMesher {

    struct Surface: Sendable {
        /// Final display colour: block colour × face shade.
        var color: SIMD3<Float>
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
    }

    /// Face-direction shade factors, indexed axis * 2 + (positive ? 0 : 1).
    /// Sun-from-above with a slight east/west bias — the voxel "lighting".
    private static let faceShades: [Float] = [0.78, 0.66, 1.0, 0.45, 0.92, 0.80]

    static func mesh(_ grid: HQVoxelGrid) -> [Surface] {
        var surfaces: [UInt16: Surface] = [:]
        let dims = [grid.sizeX, grid.sizeY, grid.sizeZ]

        grid.data.withUnsafeBufferPointer { voxels in
            @inline(__always) func block(_ p: [Int]) -> UInt8 {
                voxels[(p[1] * dims[2] + p[2]) * dims[0] + p[0]]
            }

            for axis in 0..<3 {
                let u = (axis + 1) % 3
                let v = (axis + 2) % 3
                // Mask over a slice plane: 0 = no face, +block = face pointing
                // +axis, −block = face pointing −axis.
                var mask = [Int16](repeating: 0, count: dims[u] * dims[v])
                var p = [0, 0, 0]

                for slice in 0...dims[axis] {
                    var n = 0
                    for j in 0..<dims[v] {
                        for i in 0..<dims[u] {
                            p[u] = i; p[v] = j
                            p[axis] = slice
                            let front = slice < dims[axis] ? block(p) : 0
                            p[axis] = slice - 1
                            let back = slice > 0 ? block(p) : 0
                            if (back != 0) == (front != 0) {
                                mask[n] = 0
                            } else {
                                mask[n] = back != 0 ? Int16(back) : -Int16(front)
                            }
                            n += 1
                        }
                    }

                    n = 0
                    for j in 0..<dims[v] {
                        var i = 0
                        while i < dims[u] {
                            let cell = mask[n]
                            guard cell != 0 else { i += 1; n += 1; continue }
                            var width = 1
                            while i + width < dims[u], mask[n + width] == cell { width += 1 }
                            var height = 1
                            heightLoop: while j + height < dims[v] {
                                for k in 0..<width where mask[n + height * dims[u] + k] != cell {
                                    break heightLoop
                                }
                                height += 1
                            }

                            emitQuad(
                                into: &surfaces, grid: grid, cell: cell, axis: axis, u: u, v: v,
                                slice: slice, i: i, j: j, width: width, height: height
                            )

                            for jj in 0..<height {
                                for ii in 0..<width { mask[n + jj * dims[u] + ii] = 0 }
                            }
                            i += width
                            n += width
                        }
                    }
                }
            }
        }
        return Array(surfaces.values)
    }

    private static func emitQuad(
        into surfaces: inout [UInt16: Surface],
        grid: HQVoxelGrid,
        cell: Int16, axis: Int, u: Int, v: Int,
        slice: Int, i: Int, j: Int, width: Int, height: Int
    ) {
        let positive = cell > 0
        let blockValue = UInt8(abs(cell))
        let direction = axis * 2 + (positive ? 0 : 1)
        let key = UInt16(blockValue) << 3 | UInt16(direction)

        if surfaces[key] == nil {
            let base = HQBlock(rawValue: blockValue)?.color ?? .one
            surfaces[key] = Surface(color: base * faceShades[direction])
        }

        var corner = [Float](repeating: 0, count: 3)
        corner[axis] = Float(slice)
        corner[u] = Float(i)
        corner[v] = Float(j)
        var du = [Float](repeating: 0, count: 3); du[u] = Float(width)
        var dv = [Float](repeating: 0, count: 3); dv[v] = Float(height)

        func world(_ a: [Float]) -> SIMD3<Float> {
            grid.origin + SIMD3(a[0], a[1], a[2]) * grid.voxelSize
        }
        let p0 = world(corner)
        let p1 = world([corner[0] + du[0], corner[1] + du[1], corner[2] + du[2]])
        let p2 = world([corner[0] + du[0] + dv[0], corner[1] + du[1] + dv[1], corner[2] + du[2] + dv[2]])
        let p3 = world([corner[0] + dv[0], corner[1] + dv[1], corner[2] + dv[2]])

        var normal = SIMD3<Float>.zero
        normal[axis] = positive ? 1 : -1

        var surface = surfaces[key]!
        let base = UInt32(surface.positions.count)
        surface.positions.append(contentsOf: [p0, p1, p2, p3])
        surface.normals.append(contentsOf: [normal, normal, normal, normal])
        // (u, v) = (axis+1, axis+2) makes u × v point along +axis, so the
        // 0-1-2 winding faces +axis; flip for −axis faces.
        if positive {
            surface.indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        } else {
            surface.indices.append(contentsOf: [base, base + 2, base + 1, base, base + 3, base + 2])
        }
        surfaces[key] = surface
    }

    /// One entity for a meshed grid: a child ModelEntity per surface, each
    /// with a single flat unlit material (shading is baked into the surface
    /// colours). One mesh per surface keeps the colour↔geometry binding
    /// unambiguous; it's still only ~a hundred draw calls for the whole
    /// world.
    @MainActor
    static func makeEntity(surfaces: [Surface], name: String) throws -> Entity {
        let container = Entity()
        container.name = name
        for (index, surface) in surfaces.enumerated() where !surface.positions.isEmpty {
            var descriptor = MeshDescriptor(name: "\(name).part\(index)")
            descriptor.positions = MeshBuffer(surface.positions)
            descriptor.normals = MeshBuffer(surface.normals)
            descriptor.primitives = .triangles(surface.indices)

            var material = UnlitMaterial()
            material.color = .init(tint: UIColor(
                red: CGFloat(surface.color.x),
                green: CGFloat(surface.color.y),
                blue: CGFloat(surface.color.z),
                alpha: 1
            ))
            let mesh = try MeshResource.generate(from: [descriptor])
            container.addChild(ModelEntity(mesh: mesh, materials: [material]))
        }
        return container
    }
}

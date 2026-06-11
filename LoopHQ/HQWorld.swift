import Foundation
import RealityKit
import UIKit
import simd

/// Builds and owns the Campanile environment: a sky dome, the voxel plaza +
/// tower meshed from `HQCampanileScene`, and a handful of blocky clouds.
///
/// The voxel grid is kept after meshing — it *is* the collision world.
/// Locomotion asks `walkableGround(atX:z:fromY:)` instead of raycasting:
/// a column scan in the grid is exact, allocation-free, and can't fall
/// through seams the way mesh raycasts can.
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

    private let content = Entity()
    private var grid: HQVoxelGrid?

    init() {
        root.name = "hq.worldRoot"
        content.name = "hq.content"
        root.addChild(content)
    }

    // MARK: Build

    func build() async {
        guard status == .idle else { return }
        status = .building
        await addSkyDome()

        // Generation + greedy meshing is pure CPU work over a few million
        // voxels — keep it off the main actor.
        let built = await Task.detached(priority: .userInitiated) {
            () -> (grid: HQVoxelGrid, surfaces: [HQVoxelMesher.Surface], clouds: [[HQVoxelMesher.Surface]]) in
            let grid = HQCampanileScene.build()
            let surfaces = HQVoxelMesher.mesh(grid)
            let clouds = HQCampanileScene.cloudTemplates().map { HQVoxelMesher.mesh($0) }
            return (grid, surfaces, clouds)
        }.value

        grid = built.grid
        do {
            let world = try HQVoxelMesher.makeEntity(surfaces: built.surfaces, name: "hq.campanile")
            content.addChild(world)
            try addClouds(templates: built.clouds)
            let quads = built.surfaces.reduce(0) { $0 + $1.indices.count / 6 }
            status = .ready(detail: "Campanile plaza — \(built.grid.solidCount) blocks, \(quads) faces")
        } catch {
            status = .failed("Could not build the world mesh: \(error.localizedDescription)")
        }
    }

    // MARK: Ground (gravity + collision)

    /// Step height the player can walk up — one voxel plus a little slack,
    /// so the pedestal stairs are climbable but walls, hedges and tree
    /// trunks block.
    static let maxStepUp: Float = 0.55
    /// Vertical clearance the player's body needs above the ground.
    private static let headroom: Float = 2.0

    /// The surface the player would stand on at (x, z), or nil when the
    /// move is blocked (no floor, or no headroom under an overhang).
    ///
    /// Scans the voxel column downward starting one step above `fromY`, so
    /// a wall whose top is out of step range is reported as that
    /// unreachable height and rejected by the caller's step check.
    func walkableGround(atX x: Float, z: Float, fromY: Float) -> Float? {
        guard let grid else { return 0 }  // still building: flat spawn plane
        let ix = grid.xIndex(x)
        let iz = grid.zIndex(z)
        guard ix >= 0, ix < grid.sizeX, iz >= 0, iz < grid.sizeZ else { return nil }

        var row = min(grid.yIndex(fromY + Self.maxStepUp), grid.sizeY - 1)
        while row >= 0 {
            if grid.block(ix, row, iz) != 0 {
                let clearanceRows = Int((Self.headroom / grid.voxelSize).rounded(.up))
                for above in 1...clearanceRows where grid.block(ix, row + above, iz) != 0 {
                    return nil
                }
                return grid.topOfRow(row)
            }
            row -= 1
        }
        return nil
    }

    /// Keeps a position inside the walkable plaza disc.
    static func clampToWalkable(_ position: SIMD3<Float>) -> SIMD3<Float> {
        let radius = simd_length(SIMD2(position.x, position.z))
        guard radius > HQCampanileScene.walkableRadius else { return position }
        let scale = HQCampanileScene.walkableRadius / radius
        return SIMD3(position.x * scale, position.y, position.z * scale)
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
        sphere.name = "hq.sky"
        content.addChild(sphere)
    }

    private static func makeSkyGradientImage() -> CGImage? {
        let width = 64, height = 512
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // A cheerier, slightly storybook sky than the photoreal build:
        // saturated zenith → pale horizon → soft haze below the platform.
        let colors = [
            UIColor(red: 0.30, green: 0.52, blue: 0.92, alpha: 1).cgColor,
            UIColor(red: 0.56, green: 0.76, blue: 0.97, alpha: 1).cgColor,
            UIColor(red: 0.88, green: 0.93, blue: 0.98, alpha: 1).cgColor,
            UIColor(red: 0.74, green: 0.80, blue: 0.88, alpha: 1).cgColor,
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.45, 0.55, 1]) else { return nil }
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: .zero,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        return ctx.makeImage()
    }

    // MARK: Clouds

    private func addClouds(templates: [[HQVoxelMesher.Surface]]) throws {
        var prototypes: [Int: Entity] = [:]
        for placement in HQCampanileScene.cloudPlacements {
            let (template, bearing, distance, height, yaw, scale) = placement
            let cloud: Entity
            if let prototype = prototypes[template] {
                cloud = prototype.clone(recursive: true)
            } else {
                cloud = try HQVoxelMesher.makeEntity(surfaces: templates[template], name: "hq.cloud.\(template)")
                prototypes[template] = cloud
            }
            let bearingRad = bearing * .pi / 180
            cloud.position = SIMD3(sin(bearingRad) * distance, height, -cos(bearingRad) * distance)
            cloud.orientation = simd_quatf(angle: yaw * .pi / 180, axis: SIMD3(0, 1, 0))
            cloud.scale = SIMD3(repeating: scale)
            content.addChild(cloud)
        }
    }
}

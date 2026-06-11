//
//  AvatarEntity.swift
//  LoopHQ
//
//  A simple multiplayer avatar: upright capsule (body) + floating name label.
//  Cheap enough to instantiate per-player, visually distinct enough to walk
//  up to and recognise.
//

import RealityKit
import simd

@MainActor
final class AvatarEntity {

    let root = Entity()
    let displayName: String
    private let body: ModelEntity
    private let labelEntity: Entity

    /// Colours assigned round-robin so nearby players are visually distinct.
    private static let palette: [(Float, Float, Float)] = [
        (0.30, 0.60, 0.95),  // blue
        (0.95, 0.45, 0.30),  // orange
        (0.40, 0.82, 0.45),  // green
        (0.85, 0.35, 0.75),  // pink
        (0.95, 0.80, 0.25),  // gold
        (0.50, 0.40, 0.90),  // purple
    ]
    private static var nextColorIndex = 0

    init(name: String) {
        self.displayName = name

        // Capsule body
        let h = HQConfiguration.avatarHeight
        let r = HQConfiguration.avatarRadius
        let capsuleMesh = MeshResource.generateCapsule(height: h, radius: r)

        let color = Self.palette[Self.nextColorIndex % Self.palette.count]
        Self.nextColorIndex += 1

        var mat = PhysicallyBasedMaterial()
        mat.baseColor = .init(tint: .init(red: CGFloat(color.0),
                                          green: CGFloat(color.1),
                                          blue: CGFloat(color.2),
                                          alpha: 1))
        mat.roughness = .init(floatLiteral: 0.6)
        mat.metallic  = .init(floatLiteral: 0.1)

        body = ModelEntity(mesh: capsuleMesh, materials: [mat])
        body.name = "avatar-body-\(name)"
        // Capsule origin is its centre; shift up so feet touch y = 0.
        body.position.y = h / 2
        root.addChild(body)

        // Name label (text mesh)
        let textMesh = MeshResource.generateText(
            name,
            extrusionDepth: 0.005,
            font: .systemFont(ofSize: 0.08, weight: .semibold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        var textMat = UnlitMaterial()
        textMat.color = .init(tint: .white)
        let label = ModelEntity(mesh: textMesh, materials: [textMat])
        // Centre the text horizontally (generated from left edge).
        let bounds = textMesh.bounds
        label.position.x = -bounds.extents.x / 2
        label.position.y = h + HQConfiguration.nameLabelOffset
        label.name = "avatar-label-\(name)"

        labelEntity = Entity()
        labelEntity.addChild(label)
        root.addChild(labelEntity)

        root.name = "avatar-\(name)"
    }

    // MARK: - Update from network

    func applyTransform(position: SIMD3<Float>, yaw: Float) {
        root.position = position
        root.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
    }
}

// MARK: - MeshResource capsule helper

private extension MeshResource {
    /// Generates a capsule approximation using a cylinder + two hemispheres
    /// (standard visionOS API provides `generateCapsule` — this is a safe
    /// fallback name if the SDK version differs).
    static func generateCapsule(height: Float, radius: Float) -> MeshResource {
        // RealityKit on visionOS does not expose generateCapsule publicly in
        // all SDK versions. Use a cylinder as the visual stand-in; it reads
        // well at avatar scale.
        generateCylinder(height: height, radius: radius)
    }
}

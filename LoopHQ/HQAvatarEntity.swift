import RealityKit
import UIKit
import simd

/// A simple presence avatar for a remote participant: a tinted capsule-ish
/// body, a head, and a floating name label that always faces the local
/// player. Lives in park space under the world root, so walking up to one
/// works exactly like walking anywhere else.
@MainActor
final class HQAvatarEntity: Entity {

    private static let bodyHeight: Float = 1.25
    private static let headCenter: Float = 1.52

    /// Pivot for the name text, centred above the head so billboarding spins
    /// the text around its own middle.
    private var nameLabel: Entity?
    private var labelledName = ""

    /// Pose smoothing targets (10 Hz network updates → 90 Hz rendering).
    private var targetPosition = SIMD3<Float>.zero
    private var targetYaw: Float = 0

    required init() {
        super.init()

        let tint = UIColor(hue: 0.58, saturation: 0.55, brightness: 0.95, alpha: 1)
        var bodyMaterial = UnlitMaterial()
        bodyMaterial.color = .init(tint: tint)

        let body = ModelEntity(
            mesh: .generateCylinder(height: Self.bodyHeight, radius: 0.17),
            materials: [bodyMaterial]
        )
        body.position = SIMD3(0, 0.25 + Self.bodyHeight / 2, 0)
        addChild(body)

        var headMaterial = UnlitMaterial()
        headMaterial.color = .init(tint: UIColor(white: 0.96, alpha: 1))
        let head = ModelEntity(mesh: .generateSphere(radius: 0.14), materials: [headMaterial])
        head.position = SIMD3(0, Self.headCenter, 0)
        addChild(head)
    }

    func apply(_ player: HQRemotePlayer, tintSeed: Int) {
        targetPosition = player.position
        targetYaw = player.yaw
        if player.name != labelledName {
            labelledName = player.name
            rebuildNameLabel(player.name, tintSeed: tintSeed)
        }
    }

    /// Per-frame smoothing + billboarding toward the local player.
    func tick(dt: Float, localPlayerPosition: SIMD3<Float>) {
        let lerp = min(1, 12 * dt)
        position += (targetPosition - position) * lerp
        let yawDelta = atan2(sin(targetYaw - currentYaw), cos(targetYaw - currentYaw))
        currentYaw += yawDelta * lerp
        orientation = simd_quatf(angle: -currentYaw, axis: SIMD3(0, 1, 0))

        // Keep the label readable from wherever the local player stands:
        // rotate the pivot so the text's +z faces the viewer, compensating
        // for the avatar's own yaw.
        if let nameLabel {
            let toViewer = localPlayerPosition - position
            let flat = SIMD2(toViewer.x, toViewer.z)
            if simd_length(flat) > 0.01 {
                let worldYaw = atan2(flat.x, flat.y)
                nameLabel.orientation = simd_quatf(angle: worldYaw + currentYaw, axis: SIMD3(0, 1, 0))
            }
        }
    }

    private var currentYaw: Float = 0

    private func rebuildNameLabel(_ name: String, tintSeed: Int) {
        nameLabel?.removeFromParent()

        // Tint the body per participant so groups are tellable-apart.
        let hue = CGFloat((tintSeed % 12)) / 12.0
        let tint = UIColor(hue: hue, saturation: 0.55, brightness: 0.92, alpha: 1)
        for case let model as ModelEntity in children where model.position.y < Self.headCenter - 0.1 {
            var material = UnlitMaterial()
            material.color = .init(tint: tint)
            model.model?.materials = [material]
        }

        let mesh = MeshResource.generateText(
            name,
            extrusionDepth: 0.004,
            font: .systemFont(ofSize: 0.11, weight: .semibold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        var material = UnlitMaterial()
        material.color = .init(tint: .white)
        let text = ModelEntity(mesh: mesh, materials: [material])
        // generateText lays out from the baseline origin; offset the model
        // inside a pivot so the pivot sits at the text's visual centre.
        let textBounds = text.visualBounds(relativeTo: text)
        text.position = SIMD3(-textBounds.center.x, -textBounds.center.y, 0)
        let pivot = Entity()
        pivot.position = SIMD3(0, Self.headCenter + 0.32, 0)
        pivot.addChild(text)
        nameLabel = pivot
        addChild(pivot)
    }
}

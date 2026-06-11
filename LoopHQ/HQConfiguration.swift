//
//  HQConfiguration.swift
//  LoopHQ
//
//  World constants for the Loop HQ immersive environment.
//

import simd

enum HQConfiguration {

    // MARK: - Salesforce Park, San Francisco

    /// Center of Salesforce Park (rooftop garden above Salesforce Transit Center).
    static let parkLatitude: Double  = 37.7898
    static let parkLongitude: Double = -122.3968
    /// Approximate ground elevation of the park deck (metres above sea level).
    static let parkElevation: Double = 21.0

    // MARK: - Player defaults

    /// Standing eye height: 5'10" ≈ 1.778 m.
    static let eyeHeight: Float = 1.778

    // MARK: - Terrain

    /// World-space extent of the generated terrain slab (metres).
    static let terrainExtent: Float = 300
    /// Terrain mesh subdivision count per axis.
    static let terrainSubdivisions: Int = 128
    /// Vertical scale applied to the procedural height field.
    static let terrainHeightScale: Float = 4.0

    // MARK: - Locomotion

    /// Walk speed at full pinch-drag (m/s).
    static let moveSpeed: Float = 3.0
    /// Sprint multiplier when the drag exceeds `maxDragDistance`.
    static let sprintMultiplier: Float = 2.0
    /// Maximum meaningful drag distance from the pinch origin (m in hand space).
    static let maxDragDistance: Float = 0.12
    /// Camera rotation sensitivity (radians per metre of drag).
    static let lookSensitivity: Float = 3.0
    /// Maximum pitch angle (radians) to prevent flipping.
    static let maxPitch: Float = 1.2

    // MARK: - Multiplayer / avatars

    /// Height of the capsule avatar body (m).
    static let avatarHeight: Float = 1.7
    /// Radius of the capsule avatar (m).
    static let avatarRadius: Float = 0.2
    /// How far above the capsule the name label floats (m).
    static let nameLabelOffset: Float = 0.25
    /// Network tick rate for position broadcasts (Hz).
    static let networkTickRate: Double = 15
}

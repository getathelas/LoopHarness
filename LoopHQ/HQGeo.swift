import simd

/// Geodetic constants and coordinate transforms for Loop HQ.
///
/// Loop HQ renders a real place — Salesforce Park in San Francisco — so the
/// app needs a *park-local* coordinate frame everything (tiles, avatars, the
/// player) agrees on:
///
///   * origin: a fixed anchor point at deck level in the middle of the park
///   * +x: east, +y: up, −z: north  (right-handed, matches RealityKit)
///   * units: metres
///
/// Google's photorealistic 3D Tiles arrive in earth-centred earth-fixed
/// (ECEF, z-up) coordinates, so this file owns the double-precision
/// ECEF ↔ park-frame transform. Everything else in the target works purely
/// in park-local metres.
enum HQGeo {

    // MARK: Salesforce Park

    /// Anchor at the centre of the Salesforce Park deck (above the Transit
    /// Center at 425 Mission St). Approximate to a few metres — the player
    /// spawns here and the walkable bounds are generous enough to absorb it.
    static let anchorLatitude = 37.78982
    static let anchorLongitude = -122.39633

    /// Ellipsoidal (WGS84) height of the park deck in metres. The deck sits
    /// ~21 m above street level (~3 m orthometric), and the geoid sits ~32 m
    /// *above* the ellipsoid in SF, so the ellipsoidal height is negative.
    /// Only used as a first guess for placing streamed tiles — after tiles
    /// load, the world auto-calibrates by raycasting the actual deck (see
    /// `HQWorld`).
    static let anchorEllipsoidalHeight = -8.0

    /// Compass bearing (radians clockwise from true north) of the park's
    /// long axis. The park runs parallel to Mission St, which follows the
    /// SoMa grid (~46° east of north). Approximate; bounds are generous.
    static let parkBearing = 46.0 * .pi / 180.0

    /// Walkable half-extents of the deck along (length, width) of the park's
    /// long/short axes in metres. The real deck is ~427 m × 52 m; we keep a
    /// small margin so the player can't step off the edge ("cannot clip").
    static let walkableHalfExtents = SIMD2<Double>(205, 21)

    /// Radius (m) around the anchor inside which 3D tiles are streamed.
    /// Covers the park plus the immediately surrounding blocks so towers
    /// like Salesforce Tower frame the view.
    static let tileRadius = 320.0

    // MARK: WGS84

    private static let wgs84A = 6_378_137.0
    private static let wgs84E2 = 6.694_379_990_14e-3

    /// Geodetic (radians) → ECEF metres.
    static func ecef(latitude: Double, longitude: Double, height: Double) -> SIMD3<Double> {
        let sinLat = sin(latitude), cosLat = cos(latitude)
        let n = wgs84A / (1 - wgs84E2 * sinLat * sinLat).squareRoot()
        return SIMD3(
            (n + height) * cosLat * cos(longitude),
            (n + height) * cosLat * sin(longitude),
            (n * (1 - wgs84E2) + height) * sinLat
        )
    }

    /// ECEF position of the park anchor.
    static let anchorECEF = ecef(
        latitude: anchorLatitude * .pi / 180,
        longitude: anchorLongitude * .pi / 180,
        height: anchorEllipsoidalHeight
    )

    /// Rotation whose rows are the local east / up / −north axes at the
    /// anchor, i.e. `park = rotation * (ecef − anchorECEF)`.
    static let parkFromECEFRotation: simd_double3x3 = {
        let lat = anchorLatitude * .pi / 180
        let lon = anchorLongitude * .pi / 180
        let east = SIMD3(-sin(lon), cos(lon), 0.0)
        let north = SIMD3(-sin(lat) * cos(lon), -sin(lat) * sin(lon), cos(lat))
        let up = SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
        // Rows east/up/-north == transpose of columns east/up/-north.
        return simd_double3x3(rows: [east, up, -north])
    }()

    /// Full 4×4 park-from-ECEF transform, including the glTF→ECEF axis fix.
    ///
    /// 3D Tiles content is glTF (y-up) embedded in a z-up tileset: the spec
    /// says renderers must rotate glTF +90° about X so glTF-y becomes
    /// ECEF-z. Composing that with the ENU rotation above gives one matrix
    /// to hang streamed tiles under.
    static let parkFromTileGLTF: simd_double4x4 = {
        var rot = simd_double4x4(parkFromECEFRotation)            // upper-left 3×3
        let translate = -(parkFromECEFRotation * anchorECEF)
        rot.columns.3 = SIMD4(translate, 1)
        // rotX(+90°): (x, y, z) → (x, −z, y)
        let gltfToECEF = simd_double4x4(rows: [
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 0, -1, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 0, 1),
        ])
        return rot * gltfToECEF
    }()

    /// Geodetic radians → park-local metres (for bounding-region tests).
    static func parkPosition(latitude: Double, longitude: Double, height: Double) -> SIMD3<Double> {
        parkFromECEFRotation * (ecef(latitude: latitude, longitude: longitude, height: height) - anchorECEF)
    }

    /// Clamps a park-space position to the walkable deck rectangle, which is
    /// rotated by `parkBearing` relative to north.
    static func clampToWalkableBounds(_ position: SIMD3<Float>) -> SIMD3<Float> {
        // Park frame: −z is north. Rotate by −bearing about y to express the
        // position in the deck's long/short axis frame.
        let bearing = parkBearing
        let x = Double(position.x), z = Double(position.z)
        // Long axis unit vector (points along bearing): east*sin(b) − north*… in
        // park coords: (sin b, 0, −cos b). Short axis: (cos b, 0, sin b).
        let along = x * sin(bearing) - z * cos(bearing)
        let across = x * cos(bearing) + z * sin(bearing)
        let clampedAlong = min(max(along, -walkableHalfExtents.x), walkableHalfExtents.x)
        let clampedAcross = min(max(across, -walkableHalfExtents.y), walkableHalfExtents.y)
        return SIMD3(
            Float(clampedAlong * sin(bearing) + clampedAcross * cos(bearing)),
            position.y,
            Float(-clampedAlong * cos(bearing) + clampedAcross * sin(bearing))
        )
    }
}

extension simd_double4x4 {
    init(_ m: simd_double3x3) {
        self.init(
            SIMD4(m.columns.0, 0),
            SIMD4(m.columns.1, 0),
            SIMD4(m.columns.2, 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    var asFloat4x4: simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(columns.0),
            SIMD4<Float>(columns.1),
            SIMD4<Float>(columns.2),
            SIMD4<Float>(columns.3)
        )
    }
}

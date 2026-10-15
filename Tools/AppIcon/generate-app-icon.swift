import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// generate-app-icon: draws Aeolus's app icon and writes it as a 1024 x 1024 PNG.
//
//     swift Tools/AppIcon/generate-app-icon.swift <outdir>
//
// writes <outdir>/AppIcon-1024.png. Tools/AppIcon/make-appiconset.sh runs this and then
// derives every size the asset catalog needs from that one master. See
// Tools/AppIcon/README.md.
//
// The artwork is original and is drawn here, in code, with CoreGraphics: a rounded-square
// tile with a cool blue-to-teal vertical gradient, and on it a five-bladed fan rotor in
// near-white with a slightly darker hub. Nothing is traced, sampled or downloaded. In
// particular it uses no SF Symbol (Apple's licence forbids them in app icons) and
// nothing from any other fan-control tool, per the clean-room rules in CLAUDE.md.
//
// The script is deterministic on purpose: no randomness, no clock, no environment. Run it
// twice on one machine and the bytes agree; that is what lets a reviewer regenerate the
// icon and trust that what they see is what the script says.
//
// It is not part of Package.swift or project.yml and is never built into the app. It is a
// maintainer tool, linted like everything else under Tools/.

/// Where things sit on the 1024-point canvas, following Apple's macOS icon grid: the tile
/// is 824 points square, centred, leaving a 100-point margin for its shadow, and the
/// artwork sits inside the tile with room to breathe.
private enum Geometry {
    static let canvas = 1_024
    static let canvasSide = CGFloat(canvas)
    static let tileSide: CGFloat = 824
    static let tileRect = CGRect(
        x: (canvasSide - tileSide) / 2, y: (canvasSide - tileSide) / 2,
        width: tileSide, height: tileSide)
    static let center = CGPoint(x: canvasSide / 2, y: canvasSide / 2)

    /// Exponent of the superellipse that outlines the tile. 5 puts the corners at roughly
    /// 22% of the side, matching the "continuous" corner of macOS icons, which a plain
    /// circular-arc corner does not.
    static let tileExponent: CGFloat = 5

    static let bladeCount = 5
    /// Distance from the hub centre to where a blade starts and where its tip ends.
    static let bladeInnerRadius: CGFloat = 40
    static let bladeOuterRadius: CGFloat = 292
    static let hubRadius: CGFloat = 66
    static let capRadius: CGFloat = 24
}

private enum Palette {
    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }

    // Cool blue-teal: a bright sky-cyan at the top easing down to a deep ocean blue.
    static var tileTop: CGColor { color(0x4F_D1_EC) }
    static var tileMiddle: CGColor { color(0x2A_9B_E0) }
    static var tileBottom: CGColor { color(0x15_5F_C4) }

    static var bladeTip: CGColor { color(0xFF_FF_FF) }
    static var bladeRoot: CGColor { color(0xD3_E6_F7) }
    static var hubLight: CGColor { color(0xE3_EE_F9) }
    static var hubDark: CGColor { color(0x9D_BC_DD) }
    static var hubRim: CGColor { color(0x2D_6F_B8, alpha: 0.45) }
    static var cap: CGColor { color(0x2A_78_C6) }

    static var tileShadow: CGColor { color(0x05_1E_44, alpha: 0.30) }
    static var rotorShadow: CGColor { color(0x07_2A_5C, alpha: 0.38) }
}

private func makeGradient(
    _ colors: [CGColor], at locations: [CGFloat], in space: CGColorSpace
) -> CGGradient {
    guard
        let gradient = CGGradient(
            colorsSpace: space, colors: colors as CFArray, locations: locations)
    else {
        fail("could not create a gradient")
    }
    return gradient
}

// MARK: - Tile

/// The tile's outline: a superellipse |x/a|^n + |y/a|^n = 1, sampled finely enough that
/// the polyline cannot be told from a curve at 1024 points.
private func tilePath() -> CGPath {
    let half = Geometry.tileSide / 2
    let exponent = 2 / Geometry.tileExponent
    let steps = 2_048
    let path = CGMutablePath()
    for step in 0...steps {
        let angle = 2 * CGFloat.pi * CGFloat(step) / CGFloat(steps)
        let cosine = cos(angle)
        let sine = sin(angle)
        let point = CGPoint(
            x: Geometry.center.x + half * pow(cosine.magnitude, exponent) * signOf(cosine),
            y: Geometry.center.y + half * pow(sine.magnitude, exponent) * signOf(sine))
        if step == 0 {
            path.move(to: point)
        } else {
            path.addLine(to: point)
        }
    }
    path.closeSubpath()
    return path
}

private func signOf(_ value: CGFloat) -> CGFloat {
    value < 0 ? -1 : 1
}

private func drawTile(in context: CGContext, space: CGColorSpace) {
    let outline = tilePath()
    let white = Palette.color(0xFF_FF_FF)
    let clear = Palette.color(0xFF_FF_FF, alpha: 0)

    // The shadow is cast from a solid fill, because a shadow cannot escape the clip the
    // gradient is drawn through.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: Palette.tileShadow)
    context.addPath(outline)
    context.setFillColor(Palette.tileMiddle)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(outline)
    context.clip()

    let top = CGPoint(x: Geometry.center.x, y: Geometry.tileRect.maxY)
    let bottom = CGPoint(x: Geometry.center.x, y: Geometry.tileRect.minY)
    let body = makeGradient(
        [Palette.tileTop, Palette.tileMiddle, Palette.tileBottom], at: [0, 0.5, 1], in: space)
    context.drawLinearGradient(body, start: top, end: bottom, options: [])

    // A faint glow behind the rotor lifts the middle of the tile and sets the rotor off
    // from it without drawing a second shape.
    let glow = makeGradient([white.copy(alpha: 0.22) ?? white, clear], at: [0, 1], in: space)
    context.drawRadialGradient(
        glow, startCenter: Geometry.center, startRadius: 0,
        endCenter: Geometry.center, endRadius: Geometry.tileSide * 0.48, options: [])

    // A thin light edge along the top, fading out by a third of the way down: the one
    // cue that the tile is a lit object rather than a flat colour.
    context.addPath(outline)
    context.setLineWidth(6)
    context.replacePathWithStrokedPath()
    context.clip()
    let edge = makeGradient([white.copy(alpha: 0.55) ?? white, clear], at: [0, 1], in: space)
    let fadeOut = CGPoint(x: top.x, y: top.y - Geometry.tileSide * 0.34)
    context.drawLinearGradient(edge, start: top, end: fadeOut, options: [])
    context.restoreGState()
}

// MARK: - Rotor

/// The shape of one blade, in coordinates local to the hub, pointing along +y.
///
/// The blade is built from a centreline that sweeps away from straight as it goes out,
/// and a half-width profile that grows from a narrow root to a broad paddle and closes
/// in a rounded tip. Both edges are offsets of the centreline along its normal, so the
/// shape stays smooth wherever the sweep bends it.
///
/// The half-width is shared unevenly between the two edges: more of the blade lies on the
/// outside of the bend (the leading, convex edge) than on the inside (the trailing,
/// concave one), which is what turns a symmetric petal into a swept impeller blade.
private enum Blade {
    /// How far, in radians, the tip has swung round from straight out.
    static let sweep: CGFloat = 0.8
    static let rootHalfWidth: CGFloat = 15
    static let maxHalfWidth: CGFloat = 66
    /// Where along the blade, 0 at the root and 1 at the tip, the rounded end begins.
    static let capStart: CGFloat = 0.70
    static let concaveShare: CGFloat = 0.74
    static let convexShare: CGFloat = 1.2
    static let samples = 160

    /// The centreline at `progress`, from 0 at the root to 1 at the tip.
    static func centre(_ progress: CGFloat) -> CGPoint {
        let inner = Geometry.bladeInnerRadius
        let radius = inner + (Geometry.bladeOuterRadius - inner) * progress
        let heading = CGFloat.pi / 2 + sweep * progress * progress
        return CGPoint(x: radius * cos(heading), y: radius * sin(heading))
    }

    static func halfWidth(_ progress: CGFloat) -> CGFloat {
        if progress <= capStart {
            let grown = sin(CGFloat.pi / 2 * progress / capStart)
            return rootHalfWidth + (maxHalfWidth - rootHalfWidth) * grown
        }
        let past = (progress - capStart) / (1 - capStart)
        return maxHalfWidth * (1 - past * past).squareRoot()
    }

    /// The point on each edge at `progress`: offsets of the centreline along its normal.
    static func edges(at progress: CGFloat) -> (concave: CGPoint, convex: CGPoint) {
        let ahead = centre(min(1, progress + 0.002))
        let behind = centre(max(0, progress - 0.002))
        let dx = ahead.x - behind.x
        let dy = ahead.y - behind.y
        let length = (dx * dx + dy * dy).squareRoot()
        let normal = CGPoint(x: -dy / length, y: dx / length)
        let middle = centre(progress)
        let half = halfWidth(progress)
        let concave = half * concaveShare
        let convex = half * convexShare
        return (
            CGPoint(x: middle.x + normal.x * concave, y: middle.y + normal.y * concave),
            CGPoint(x: middle.x - normal.x * convex, y: middle.y - normal.y * convex)
        )
    }
}

/// One blade, outlined root to tip along its convex edge and back along its concave one,
/// then rotated about the hub by `angle` into place.
private func bladeOutline(rotatedBy angle: CGFloat) -> CGPath {
    let edges = (0...Blade.samples).map { Blade.edges(at: CGFloat($0) / CGFloat(Blade.samples)) }

    let local = CGMutablePath()
    local.move(to: edges[0].convex)
    for edge in edges.dropFirst() {
        local.addLine(to: edge.convex)
    }
    for edge in edges.reversed() {
        local.addLine(to: edge.concave)
    }
    local.closeSubpath()

    var transform = CGAffineTransform(translationX: Geometry.center.x, y: Geometry.center.y)
        .rotated(by: angle)
    guard let placed = local.copy(using: &transform) else {
        fail("could not place a blade")
    }
    return placed
}

private func hubPath(radius: CGFloat) -> CGPath {
    CGPath(
        ellipseIn: CGRect(
            x: Geometry.center.x - radius, y: Geometry.center.y - radius,
            width: radius * 2, height: radius * 2),
        transform: nil)
}

private func drawRotor(in context: CGContext, space: CGColorSpace) {
    let step = 2 * CGFloat.pi / CGFloat(Geometry.bladeCount)
    let blades = (0..<Geometry.bladeCount).map { bladeOutline(rotatedBy: CGFloat($0) * step) }

    // One shadow for the whole rotor, cast by the blades and hub together.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: Palette.rotorShadow)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setFillColor(Palette.bladeTip)
    for blade in blades {
        context.addPath(blade)
        context.fillPath()
    }
    context.addPath(hubPath(radius: Geometry.hubRadius))
    context.fillPath()
    context.endTransparencyLayer()
    context.restoreGState()

    // Each blade shades from a cool tint at the root to white at the tip, so the blades
    // read as dipping toward the hub rather than lying flat on the tile.
    let shade = makeGradient([Palette.bladeRoot, Palette.bladeTip], at: [0, 0.8], in: space)
    for (index, blade) in blades.enumerated() {
        let angle = CGFloat(index) * step
        let start = CGPoint(
            x: Geometry.center.x - Geometry.bladeInnerRadius * sin(angle),
            y: Geometry.center.y + Geometry.bladeInnerRadius * cos(angle))
        let end = CGPoint(
            x: Geometry.center.x - Geometry.bladeOuterRadius * sin(angle),
            y: Geometry.center.y + Geometry.bladeOuterRadius * cos(angle))
        context.saveGState()
        context.addPath(blade)
        context.clip()
        context.drawLinearGradient(shade, start: start, end: end, options: [.drawsAfterEndLocation])
        context.restoreGState()
    }

    drawHub(in: context, space: space)
}

private func drawHub(in context: CGContext, space: CGColorSpace) {
    let hub = hubPath(radius: Geometry.hubRadius)
    context.saveGState()
    context.addPath(hub)
    context.clip()
    let dome = makeGradient([Palette.hubLight, Palette.hubDark], at: [0, 1], in: space)
    let highlight = CGPoint(
        x: Geometry.center.x - Geometry.hubRadius * 0.3,
        y: Geometry.center.y + Geometry.hubRadius * 0.3)
    context.drawRadialGradient(
        dome, startCenter: highlight, startRadius: 0,
        endCenter: Geometry.center, endRadius: Geometry.hubRadius * 1.15,
        options: [.drawsAfterEndLocation])
    context.restoreGState()

    context.addPath(hub)
    context.setStrokeColor(Palette.hubRim)
    context.setLineWidth(3)
    context.strokePath()

    context.addPath(hubPath(radius: Geometry.capRadius))
    context.setFillColor(Palette.cap)
    context.fillPath()
}

// MARK: - Output

private func renderIcon() -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil, width: Geometry.canvas, height: Geometry.canvas,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
        return nil
    }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    drawTile(in: context, space: space)
    drawRotor(in: context, space: space)
    return context.makeImage()
}

private func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        return false
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-app-icon: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fail("usage: swift Tools/AppIcon/generate-app-icon.swift <outdir>")
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true)
} catch {
    fail("cannot create \(outputDirectory.path): \(error.localizedDescription)")
}
guard let icon = renderIcon() else {
    fail("could not create a drawing context")
}
let destination = outputDirectory.appendingPathComponent("AppIcon-1024.png")
guard writePNG(icon, to: destination) else {
    fail("could not write \(destination.path)")
}
print(destination.path)

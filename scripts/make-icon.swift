// 生成 PinShot 的熊猫主题 App 图标。
// 用法：swift scripts/make-icon.swift
// 产物：build/AppIcon.iconset/ + Resources/AppIcon.icns + build/panda-icon-1024.png
import AppKit
import Foundation

let canvasSize = 1024.0
let outputRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let buildDir = outputRoot.appendingPathComponent("build")
try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize),
    pixelsHigh: Int(canvasSize),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
let graphics = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let ctx = graphics.cgContext

// 使用左上原点坐标，方便按设计稿排版
ctx.translateBy(x: 0, y: canvasSize)
ctx.scaleBy(x: 1, y: -1)

// MARK: - 调色

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}
let orange = color(0xFF7A45)
let orangeDeep = color(0xE8551F)
let ink = color(0x141518)
let paper = color(0xF7F4EE)
let paperShade = color(0xE9E4D9)

// MARK: - 圆角方块背景

let iconRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: iconRect, xRadius: 190, yRadius: 190)
squircle.addClip()

let bg = NSGradient(colors: [color(0x2E323B), color(0x15161A)])!
bg.draw(in: iconRect, angle: 90)

// 内描边
squircle.lineWidth = 4
paper.withAlphaComponent(0.08).setStroke()
squircle.stroke()

// MARK: - 熊猫

// 耳朵（黑色，位于脸后面）
func ellipse(center: CGPoint, width: CGFloat, height: CGFloat, rotation: CGFloat = 0) -> NSBezierPath {
    let path = NSBezierPath(ovalIn: NSRect(x: -width / 2, y: -height / 2, width: width, height: height))
    var transform = AffineTransform.identity
    transform.translate(x: center.x, y: center.y)
    transform.rotate(byDegrees: rotation)
    path.transform(using: transform)
    return path
}

let earColor = color(0x111214)
earColor.setFill()
ellipse(center: CGPoint(x: 338, y: 330), width: 210, height: 210, rotation: -16).fill()
ellipse(center: CGPoint(x: 686, y: 330), width: 210, height: 210, rotation: 16).fill()

// 脸部：上方略窄、脸颊圆润的熊猫脸
let face = NSBezierPath()
face.move(to: CGPoint(x: 258, y: 470))
face.curve(to: CGPoint(x: 512, y: 282),
           controlPoint1: CGPoint(x: 262, y: 342),
           controlPoint2: CGPoint(x: 380, y: 282))
face.curve(to: CGPoint(x: 766, y: 470),
           controlPoint1: CGPoint(x: 644, y: 282),
           controlPoint2: CGPoint(x: 762, y: 342))
face.curve(to: CGPoint(x: 512, y: 766),
           controlPoint1: CGPoint(x: 770, y: 650),
           controlPoint2: CGPoint(x: 674, y: 766))
face.curve(to: CGPoint(x: 258, y: 470),
           controlPoint1: CGPoint(x: 350, y: 766),
           controlPoint2: CGPoint(x: 254, y: 650))
face.close()

NSGraphicsContext.saveGraphicsState()
let faceShadow = NSShadow()
faceShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
faceShadow.shadowBlurRadius = 30
faceShadow.shadowOffset = NSSize(width: 0, height: -10)
faceShadow.set()
paper.setFill()
face.fill()
NSGraphicsContext.restoreGraphicsState()

// 脸部下方轻微阴影
let faceGradient = NSGradient(colors: [paper, paperShade])!
faceGradient.draw(in: face, angle: -90)

// 眼圈
let patch = color(0x111214)
patch.setFill()
ellipse(center: CGPoint(x: 402, y: 482), width: 168, height: 200, rotation: 18).fill()
ellipse(center: CGPoint(x: 622, y: 482), width: 168, height: 200, rotation: -18).fill()

// 眼睛
NSColor.white.setFill()
ellipse(center: CGPoint(x: 408, y: 500), width: 58, height: 64).fill()
ellipse(center: CGPoint(x: 616, y: 500), width: 58, height: 64).fill()

color(0x0B0B0C).setFill()
ellipse(center: CGPoint(x: 406, y: 508), width: 30, height: 34).fill()
ellipse(center: CGPoint(x: 618, y: 508), width: 30, height: 34).fill()

NSColor.white.withAlphaComponent(0.9).setFill()
ellipse(center: CGPoint(x: 397, y: 497), width: 11, height: 11).fill()
ellipse(center: CGPoint(x: 609, y: 497), width: 11, height: 11).fill()

// 鼻子
color(0x0B0B0C).setFill()
let nose = NSBezierPath()
nose.move(to: CGPoint(x: 486, y: 610))
nose.curve(to: CGPoint(x: 512, y: 596), controlPoint1: CGPoint(x: 492, y: 592), controlPoint2: CGPoint(x: 503, y: 596))
nose.curve(to: CGPoint(x: 538, y: 610), controlPoint1: CGPoint(x: 521, y: 596), controlPoint2: CGPoint(x: 532, y: 592))
nose.curve(to: CGPoint(x: 520, y: 642), controlPoint1: CGPoint(x: 540, y: 628), controlPoint2: CGPoint(x: 534, y: 640))
nose.curve(to: CGPoint(x: 504, y: 642), controlPoint1: CGPoint(x: 512, y: 645), controlPoint2: CGPoint(x: 510, y: 642))
nose.curve(to: CGPoint(x: 486, y: 610), controlPoint1: CGPoint(x: 492, y: 640), controlPoint2: CGPoint(x: 484, y: 628))
nose.close()
nose.fill()

// 嘴巴
let smile = NSBezierPath()
smile.lineWidth = 8
smile.lineCapStyle = .round
smile.move(to: CGPoint(x: 512, y: 642))
smile.line(to: CGPoint(x: 512, y: 662))
smile.move(to: CGPoint(x: 512, y: 662))
smile.curve(to: CGPoint(x: 472, y: 676), controlPoint1: CGPoint(x: 500, y: 680), controlPoint2: CGPoint(x: 486, y: 682))
smile.move(to: CGPoint(x: 512, y: 662))
smile.curve(to: CGPoint(x: 552, y: 676), controlPoint1: CGPoint(x: 524, y: 680), controlPoint2: CGPoint(x: 538, y: 682))
color(0x1A1A1B).setStroke()
smile.stroke()

// 腮红
orange.withAlphaComponent(0.22).setFill()
ellipse(center: CGPoint(x: 336, y: 590), width: 90, height: 54).fill()
ellipse(center: CGPoint(x: 688, y: 590), width: 90, height: 54).fill()

// MARK: - 图钉徽章（SF Symbol，清晰且不抢熊猫主体）

func tintedPin(size: CGFloat, color: NSColor) -> NSImage? {
    guard let base = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil) else { return nil }
    let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
    guard let symbol = base.withSymbolConfiguration(configuration) else { return nil }
    symbol.isTemplate = true
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    color.set()
    NSRect(origin: .zero, size: symbol.size).fill()
    symbol.draw(in: NSRect(origin: .zero, size: symbol.size), from: .zero, operation: .destinationIn, fraction: 1)
    tinted.unlockFocus()
    return tinted
}

if let pin = tintedPin(size: 150, color: orange) {
    ctx.saveGState()
    ctx.translateBy(x: 824, y: 224)
    ctx.rotate(by: 12 * .pi / 180)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let pinRect = NSRect(x: -pin.size.width / 2, y: -pin.size.height / 2, width: pin.size.width, height: pin.size.height)
    pin.draw(in: pinRect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()
}

NSGraphicsContext.restoreGraphicsState()

// 输出 1024 PNG 与 iconset
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: buildDir.appendingPathComponent("panda-icon-1024.png"))

let iconsetDir = buildDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x")
]
for (pixels, name) in sizes {
    let resized = NSImage(size: NSSize(width: pixels, height: pixels))
    resized.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: rep.cgImage!, size: NSSize(width: canvasSize, height: canvasSize)).draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .copy, fraction: 1
    )
    resized.unlockFocus()
    guard let tiff = resized.tiffRepresentation,
          let smallRep = NSBitmapImageRep(data: tiff),
          let data = smallRep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: iconsetDir.appendingPathComponent("\(name).png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path, "-o", outputRoot.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print("icon generated: \(process.terminationStatus == 0 ? "OK" : "FAILED")")

// app/AppIcon.svg から、アプリのアイコン app/AppIcon.icns を作る。AppIcon.svg を描き直したときに実行する
//   swift scripts/make_icon.swift
import AppKit

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let svg = repo.appending(path: "app/AppIcon.svg")
let icns = repo.appending(path: "app/AppIcon.icns")
guard let image = NSImage(contentsOf: svg) else {
    FileHandle.standardError.write(Data("\(svg.path) を読めません\n".utf8))
    exit(1)
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// iconutil が求める大きさと名前で、1 倍と 2 倍の画像を書き出す
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        // SVG の色をそのまま使うため、sRGB の画像に描く
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appending(path: name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("アイコン: \(icns.path)")

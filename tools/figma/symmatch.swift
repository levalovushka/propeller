import AppKit
import CoreText

let side = 128
let names: [String] = {
    let url = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/symbol_order.plist")
    let data = try! Data(contentsOf: url)
    let list = try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String]
    return list
}()

func bitmap(_ draw: (CGContext) -> Void) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: side * side)
    var rgba = [UInt8](repeating: 0, count: side * side * 4)
    rgba.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.setFillColor(NSColor.white.cgColor)
        draw(ctx)
    }
    for i in 0..<(side * side) { buf[i] = rgba[i * 4] }
    return buf
}

/// Нормализуем: обрезаем по bbox туши и растягиваем в квадрат — так сравнение
/// не зависит от того, как символ сидит в своей строке.
func normalized(_ b: [UInt8]) -> [UInt8] {
    var minX = side, maxX = -1, minY = side, maxY = -1
    for y in 0..<side { for x in 0..<side where b[y * side + x] > 40 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
    guard maxX >= minX, maxY >= minY else { return [UInt8](repeating: 0, count: 40 * 40) }
    let w = maxX - minX + 1, h = maxY - minY + 1
    // Квадрат с сохранением пропорции: широкий символ не растягиваем в узкий.
    let box = max(w, h)
    let padX = (box - w) / 2, padY = (box - h) / 2
    let n = 40
    var out = [UInt8](repeating: 0, count: n * n)
    for oy in 0..<n { for ox in 0..<n {
        let bx = ox * box / n - padX, by = oy * box / n - padY
        guard bx >= 0, bx < w, by >= 0, by < h else { continue }
        out[oy * n + ox] = b[(minY + by) * side + (minX + bx)] } }
    return out
}

func distance(_ a: [UInt8], _ b: [UInt8]) -> Int {
    var d = 0
    for i in 0..<a.count { d += abs(Int(a[i]) - Int(b[i])) }
    return d
}

// эталоны: символы по имени
var library: [(String, [UInt8])] = []
let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(side) * 0.7, weight: .regular)
for name in names {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { continue }
    let b = bitmap { ctx in
        let r = NSRect(x: 0, y: 0, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let tinted = NSImage(size: r.size, flipped: false) { rect in
            NSColor.white.set()
            img.draw(in: NSRect(x: (rect.width - img.size.width) / 2,
                                y: (rect.height - img.size.height) / 2,
                                width: img.size.width, height: img.size.height))
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
    }
    library.append((name, normalized(b)))
}
FileHandle.standardError.write("library \(library.count)\n".data(using: .utf8)!)

// цели: глифы по кодпойнту из шрифта SF Pro
let font = NSFont(name: "SF Pro Text", size: CGFloat(side) * 0.7)
    ?? NSFont.systemFont(ofSize: CGFloat(side) * 0.7)
for arg in CommandLine.arguments.dropFirst() {
    guard let cp = UInt32(arg, radix: 16), let scalar = Unicode.Scalar(cp) else { continue }
    let s = String(Character(scalar))
    let target = normalized(bitmap { ctx in
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.white])
        let sz = attr.size()
        attr.draw(at: NSPoint(x: (CGFloat(side) - sz.width) / 2, y: (CGFloat(side) - sz.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
    })
    let best = library.map { ($0.0, distance($0.1, target)) }.sorted { $0.1 < $1.1 }.prefix(4)
    print("U+\(arg.uppercased()): " + best.map { "\($0.0) (\($0.1))" }.joined(separator: ", "))
}

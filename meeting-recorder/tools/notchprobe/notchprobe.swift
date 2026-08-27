import AppKit

_ = NSApplication.shared

for screen in NSScreen.screens {
    let f = screen.frame
    let top = screen.safeAreaInsets.top
    let name = screen.localizedName
    print("Экран: \(name)")
    print("  frame (pt):        \(Int(f.width)) × \(Int(f.height))  origin \(Int(f.minX)),\(Int(f.minY))")
    print("  backingScale:      \(screen.backingScaleFactor)")
    print("  safeAreaInsets.top:\(top)   ← высота выреза")
    if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
        let cut = f.width - l.width - r.width
        print("  auxTopLeft (pt):   \(l.width) × \(l.height)")
        print("  auxTopRight (pt):  \(r.width) × \(r.height)")
        print("  ВЫРЕЗ (pt):        \(cut) × \(top)")
        print("  ВЫРЕЗ (px):        \(cut * screen.backingScaleFactor) × \(top * screen.backingScaleFactor)")
        print("  вырез от ширины:   \(String(format: "%.1f", cut / f.width * 100)) %")

        if let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let modes = CGDisplayCopyAllDisplayModes(CGDirectDisplayID(display.uint32Value), nil) as? [CGDisplayMode] {
            // Вырез физически не меняется — меняется масштаб. Значит в любом
            // режиме он занимает ту же долю логической ширины, что и сейчас.
            let share = cut / f.width
            let heightShare = top / f.width
            let scale = screen.backingScaleFactor
            print("  --- тот же вырез в других разрешениях ---")
            var seen = Set<CGFloat>()
            for mode in modes.sorted(by: { $0.width > $1.width }) {
                let logical = CGFloat(mode.width) / scale
                guard logical >= 800, !seen.contains(logical) else { continue }
                seen.insert(logical)
                print(String(format: "    рабочий стол %.0f pt → вырез %.1f × %.1f pt",
                             logical, share * logical, heightShare * logical))
            }
        }
    } else {
        print("  выреза нет (auxiliaryTop*Area == nil)")
    }
    print("")
}

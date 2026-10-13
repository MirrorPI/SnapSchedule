import AppKit
import Foundation
struct Fixture: Codable { let id: String; let category: String; let lines: [String]; let days: [Int]; let hours: [Int] }
var fixtures: [Fixture] = []
for index in 1...8 { fixtures.append(Fixture(id: String(format: "none-%02d", index), category: "none", lines: ["SYNTHETIC SAMPLE", "No appointment information", "A quiet landscape"], days: [], hours: [])) }
for index in 1...8 {
    let day = index <= 2 ? 20 : 20 + index
    fixtures.append(Fixture(id: String(format: "single-%02d", index), category: "single", lines: ["SYNTHETIC SAMPLE", "Workshop 2027-01-\(day) 14:00"], days: [day], hours: [14]))
}
for index in 1...2 { fixtures.append(Fixture(id: String(format: "multi-%02d", index), category: "multi", lines: ["SYNTHETIC SAMPLE", "Session Alpha 2027-01-20 09:00", "Session Beta 2027-01-21 15:00"], days: [20, 21], hours: [9, 15])) }
for index in 1...2 { fixtures.append(Fixture(id: String(format: "edit-%02d", index), category: "edit", lines: ["2027-01-29 2:00 PM"], days: [29], hours: [14])) }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(fixtures).write(to: directory.appendingPathComponent("manifest.json"))
for fixture in fixtures {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 1800, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 1800).fill()
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .medium), .foregroundColor: NSColor.black]
    for (index, line) in fixture.lines.enumerated() { (line as NSString).draw(at: NSPoint(x: 70, y: 1560 - index * 160), withAttributes: attributes) }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(fixture.id + ".png"))
}
print("Generated \(fixtures.count) synthetic images; no photo library access")

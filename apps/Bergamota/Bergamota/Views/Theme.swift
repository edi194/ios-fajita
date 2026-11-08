import SwiftUI
import AppKit
import CoreText

// The Bergamota identity (tools/identity/IDENTITY.md) as the app's design system: palette, the two typefaces, the
// halftone ground, and the few components every page shares. Colours that sit on the work area adapt to the dark
// appearance (paper and ink swap); the lime stage and the ink console keep their colours in both.

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)
    }

    /// One colour for the aqua appearance, another for dark aqua.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { ap in
            let h = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1)
        })
    }

    // fixed identity colours
    static let lime = Color(hex: 0xd7e98a)          // the stage, Bergamota fastboot
    static let limeDot = Color(hex: 0xc6dc72)       // the stage's halftone dots
    static let ink = Color(hex: 0x161616)           // the console, type on the stage
    static let paper = Color(hex: 0xf4f3ec)
    static let leaf = Color(hex: 0x1a5933)          // primary actions, iOS up
    static let alert = Color(hex: 0xb3261e)         // writes the phone, failures, panic
    static let amber = Color(hex: 0xe8a33a)         // ABL fastboot, waiting
    static let consoleLine = Color(hex: 0x2c2c29)   // rules on the ink console
    static let consoleMuted = Color(hex: 0x9a9992)  // secondary text on the ink console
    static let alertOnInk = Color(hex: 0xff6a5a)

    // the work area (paper in light, ink in dark)
    static let ground = Color(light: 0xf4f3ec, dark: 0x141413)
    static let surface = Color(light: 0xfbfaf5, dark: 0x1e1e1c)
    static let rule = Color(light: 0xe2e0d6, dark: 0x2e2e2b)
    static let text = Color(light: 0x161616, dark: 0xf4f3ec)
    static let muted = Color(light: 0x66655f, dark: 0xa3a29b)
    static let leafText = Color(light: 0x1a5933, dark: 0x9ccf86)
    static let alertText = Color(light: 0xb3261e, dark: 0xff7b6b)
    static let amberText = Color(light: 0x8a4d00, dark: 0xf0b860)
}

/// The phone state as the identity paints it: a fill and the type that reads on it.
struct Tone: Equatable {
    var fill: Color
    var on: Color
    static let leaf = Tone(fill: .leaf, on: .paper)
    static let lime = Tone(fill: .lime, on: .ink)
    static let ink = Tone(fill: .ink, on: .lime)
    static let amber = Tone(fill: .amber, on: .ink)
    static let alert = Tone(fill: .alert, on: .paper)
    static let quiet = Tone(fill: Color(hex: 0x8d8c85), on: .paper)
}

func stateTone(_ s: PhoneState) -> Tone {
    switch s {
    case .ios: .leaf
    case .fastboot: .amber
    case .bergamotaFastboot: .ink
    case .recovery, .android: .ink
    case .iosBooting: .amber
    case .offline, .unknown: .quiet
    }
}

/// Text/icon colour for a state on the work area.
func stateColor(_ s: PhoneState) -> Color {
    switch s {
    case .ios: .leafText
    case .fastboot, .iosBooting: .amberText
    case .bergamotaFastboot: .leafText
    case .recovery, .android: .text
    case .offline, .unknown: .muted
    }
}

// MARK: type

/// Archivo (display) and JetBrains Mono (data), bundled as the identity's own woff2 files and loaded through CoreText
/// with their variation axes set, so the app uses exactly the faces the phone screens and the icon were drawn with.
@MainActor
enum BFont {
    private static var base: [String: CTFontDescriptor] = [:]
    private static var cache: [String: Font] = [:]
    private static let wght = 0x77676874 as NSNumber, wdth = 0x77647468 as NSNumber

    private static func descriptor(_ file: String) -> CTFontDescriptor? {
        if let d = base[file] { return d }
        guard let url = Bundle.main.url(forResource: file, withExtension: "woff2"),
              let data = try? Data(contentsOf: url),
              let d = (CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor])?.first else { return nil }
        base[file] = d
        return d
    }

    private static func make(_ file: String, _ size: CGFloat, _ axes: [NSNumber: CGFloat], fallback: Font) -> Font {
        let key = "\(file)|\(size)|\(axes.sorted { $0.key.intValue < $1.key.intValue }.map { "\($0.value)" }.joined(separator: ","))"
        if let f = cache[key] { return f }
        guard let d = descriptor(file) else { return fallback }
        let v = CTFontDescriptorCreateCopyWithAttributes(d, [kCTFontVariationAttribute: axes] as CFDictionary)
        let f = Font(CTFontCreateWithFontDescriptor(v, size, nil))
        cache[key] = f
        return f
    }

    /// Archivo 900 at 112 % width: page titles, state words, big numbers.
    static func display(_ size: CGFloat) -> Font {
        make("archivo", size, [wght: 900, wdth: 112], fallback: .system(size: size, weight: .black))
    }

    /// JetBrains Mono: values, paths, commands, logs.
    static func mono(_ size: CGFloat, _ weight: CGFloat = 400) -> Font {
        make("jetbrains-mono", size, [wght: weight], fallback: .system(size: size, design: .monospaced))
    }
}

// MARK: halftone

/// The identity's lime ground: lime with a 14 pt grid of slightly darker dots.
struct HalftoneGround: View {
    var color: Color = .lime
    var dot: Color = .limeDot
    var body: some View {
        Canvas { g, size in
            g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color))
            let step: CGFloat = 14, r: CGFloat = 1.6
            var p = Path()
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width {
                    p.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                    x += step
                }
                y += step
            }
            g.fill(p, with: .color(dot))
        }
        .accessibilityHidden(true)
    }
}

/// Ink dots growing from nothing at the top to solid at the bottom, as the phone screens' coat dissolves into
/// their console panel.
struct HalftoneDissolve: View {
    var color: Color = .ink
    var cell: CGFloat = 7
    var body: some View {
        Canvas { g, size in
            var p = Path()
            let rows = Int(size.height / cell) + 1, cols = Int(size.width / cell) + 1
            for j in 0..<rows {
                let t = (CGFloat(j) + 0.5) / CGFloat(rows)
                let r = cell * 0.72 * t * t
                guard r > 0.25 else { continue }
                for i in 0..<cols {
                    let cx = (CGFloat(i) + (j % 2 == 0 ? 0.5 : 1)) * cell, cy = (CGFloat(j) + 0.5) * cell
                    p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
                }
            }
            g.fill(p, with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

// MARK: components

/// Page title in Archivo with an optional line under it and trailing controls.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(BFont.display(30)).foregroundStyle(Color.text)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(Color.muted).lineLimit(2) }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

/// Capitals for labels, keeping the product's own spelling of iOS.
func caps(_ s: String) -> String { s.uppercased().replacingOccurrences(of: "IOS", with: "iOS") }

/// A section heading inside a page: small mono capitals.
struct Label12: View {
    let text: String
    var color: Color = .muted
    var body: some View {
        Text(caps(text)).font(BFont.mono(11, 800)).tracking(1.3).foregroundStyle(color)
    }
}

/// The work area's one container: surface fill, a hairline, 12 pt corners, no shadow.
struct Panel<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.muted) }
                    Label12(text: title)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.rule))
    }
}

/// A key/value line: label in the UI face, value in mono, an optional ok/not-ok mark.
struct Row: View {
    let k: String
    let v: String
    var ok: Bool? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(k).font(.callout).foregroundStyle(Color.muted)
            Spacer(minLength: 12)
            if let ok {
                Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle").font(.system(size: 11))
                    .foregroundStyle(ok ? Color.leafText : Color.muted)
            }
            Text(v).font(BFont.mono(12)).foregroundStyle(Color.text).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.rule).frame(height: 1).offset(y: 3) }
    }
}

/// A small capsule label: state, status, flags.
struct Pill: View {
    let text: String
    var tone: Tone = .ink
    var size: CGFloat = 10.5
    var body: some View {
        Text(caps(text)).font(BFont.mono(size, 800)).tracking(0.6).lineLimit(1)
            .padding(.horizontal, size * 0.85).padding(.vertical, size * 0.3)
            .background(tone.fill, in: Capsule()).foregroundStyle(tone.on)
    }
}

/// A notice line on the work area (warnings, errors, hints with a fix).
struct Notice: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var color: Color = .amberText
    var body: some View {
        Label { Text(text).foregroundStyle(Color.text).lineLimit(4) } icon: { Image(systemName: symbol).foregroundStyle(color) }
            .font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
}

/// An empty state on the identity's lime stage: what is missing and how to get it, in ink.
struct EmptyStage: View {
    let title: String
    let text: String
    var symbol: String = "circle.dashed"
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
            Text(title).font(BFont.display(22))
            Text(text).font(.callout).lineLimit(3)
        }
        .foregroundStyle(Color.ink)
        .padding(22)
        .frame(maxWidth: 440, alignment: .leading)
        .background { HalftoneGround().clipShape(RoundedRectangle(cornerRadius: 12)) }
    }
}

/// Command output and logs: the ink console, paper mono text, following the end.
struct ConsolePane: View {
    let text: String
    var placeholder: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? placeholder : text)
                    .font(BFont.mono(11.5)).lineSpacing(2)
                    .foregroundStyle(text.isEmpty ? Color.consoleMuted : Color.paper)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Color.clear.frame(height: 1).id("end")
            }
            .background(Color.ink)
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// A drop target: a dashed hairline that fills lime while something hovers over it.
struct DropZoneStyle: ViewModifier {
    var targeted: Bool
    func body(content: Content) -> some View {
        content
            .background(targeted ? Color.lime.opacity(0.55) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.leafText : Color.muted.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }
}

extension View {
    func dropZone(_ targeted: Bool) -> some View { modifier(DropZoneStyle(targeted: targeted)) }
    /// The standard page frame: work-area ground, title out of the toolbar (the page header carries it).
    func page(_ title: String) -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.ground)
            .navigationTitle(title)
    }
}

/// Status glyph of a queue item, shared by the Boot page, the rail and the Control Plane.
func queueStatusSymbol(_ s: QueueItem.Status) -> String {
    switch s { case .pending: "clock"; case .sending: "paperplane.fill"; case .sent: "checkmark.circle.fill"; case .failed: "xmark.octagon.fill" }
}
func queueStatusColor(_ s: QueueItem.Status) -> Color {
    switch s { case .pending: .muted; case .sending: .amberText; case .sent: .leafText; case .failed: .alertText }
}

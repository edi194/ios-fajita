import SwiftUI

/// What the app is doing or seeing right now (AppModel.activityBanner), as a band in the state's tone: the title in
/// Archivo, the detail in mono, a progress track when the work has one. The Control Plane shows it large.
struct ActivityBannerView: View {
    @Environment(AppModel.self) private var model
    var big = false
    /// Control Plane layout scale (fits an iPad Sidecar display); 1 elsewhere.
    var scale: CGFloat = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let b = model.activityBanner(now: ctx.date)
            let s = scale, radius: CGFloat = (big ? 26 : 14) * s
            HStack(spacing: (big ? 28 : 16) * s) {
                Image(systemName: b.symbol).font(.system(size: (big ? 50 : 28) * s, weight: .semibold))
                VStack(alignment: .leading, spacing: (big ? 10 : 4) * s) {
                    Text(b.title).font(BFont.display((big ? 50 : 28) * s)).lineLimit(1).minimumScaleFactor(0.4)
                        .modifier(StateStep(key: b.title, mark: b.tone.on))
                    if !b.subtitle.isEmpty {
                        Text(b.subtitle).font(BFont.mono((big ? 18 : 12) * s)).lineLimit(2).opacity(0.82)
                    }
                    if let p = b.progress {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(b.tone.on.opacity(0.2))
                                Capsule().fill(b.tone.on).frame(width: max(10 * s, g.size.width * min(max(p, 0), 1)))
                            }
                        }
                        .frame(height: (big ? 12 : 6) * s)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(b.tone.on)
            .padding((big ? 22 : 16) * s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if b.tone == .lime { HalftoneGround().clipShape(RoundedRectangle(cornerRadius: radius)) }
                else { RoundedRectangle(cornerRadius: radius).fill(b.tone.fill) }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

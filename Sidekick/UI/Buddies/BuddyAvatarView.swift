import SwiftUI

/// Buddy avatar: a fluffy pastel cloud with closed happy "^^" eyes on a soft circle. Generated, no assets.
struct BuddyAvatarView: View {
    let preset: String
    var size: CGFloat = 22

    var body: some View {
        let (_, hue) = BuddyAvatar.parse(preset)
        let h = Double(hue) / 8.0
        let cloudTop = Color(hue: h, saturation: 0.42, brightness: 1.0)
        let cloudBottom = Color(hue: h + 0.04, saturation: 0.55, brightness: 0.93)
        let backdrop = Color(hue: h + 0.5, saturation: 0.18, brightness: 0.98)
        ZStack {
            Circle().fill(backdrop)
            CloudShape()
                .fill(LinearGradient(colors: [cloudTop, cloudBottom], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.82, height: size * 0.6)
                .shadow(color: cloudBottom.opacity(0.5), radius: size * 0.05, y: size * 0.02)
            HappyEyes()
                .stroke(Color.white, style: StrokeStyle(lineWidth: max(1, size * 0.055), lineCap: .round))
                .frame(width: size * 0.34, height: size * 0.08)
                .offset(y: size * 0.02)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Bumpy cloud: a capsule body with three puffs on top.
struct CloudShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY + h * 0.38, width: w, height: h * 0.62), cornerSize: CGSize(width: h * 0.31, height: h * 0.31))
        p.addEllipse(in: CGRect(x: r.minX + w * 0.08, y: r.minY + h * 0.18, width: w * 0.42, height: h * 0.62))
        p.addEllipse(in: CGRect(x: r.minX + w * 0.32, y: r.minY, width: w * 0.42, height: h * 0.72))
        p.addEllipse(in: CGRect(x: r.minX + w * 0.55, y: r.minY + h * 0.2, width: w * 0.38, height: h * 0.58))
        return p
    }
}

/// Two "^" arcs — closed, smiling eyes.
struct HappyEyes: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let ew = r.width * 0.36
        for x in [r.minX, r.maxX - ew] {
            p.move(to: CGPoint(x: x, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: x + ew, y: r.maxY), control: CGPoint(x: x + ew / 2, y: r.minY - r.height))
        }
        return p
    }
}

/// The "Suggestions" avatar: violet→pink gradient circle with a sparkle.
struct SuggestionsAvatar: View {
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color(red: 0.62, green: 0.52, blue: 0.96), Color(red: 0.95, green: 0.55, blue: 0.75)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "sparkles").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

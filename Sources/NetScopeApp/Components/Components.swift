#if os(macOS)
import SwiftUI
import NetScopeCore

// MARK: - Liquid Glass with native fallback

/// Uses the native Liquid Glass material (macOS 26+, built with the macOS 26 SDK) and falls back to
/// the system `.regularMaterial` on earlier versions. No hand-made blur or transparency tricks.
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 16
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        #else
        content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #endif
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 16) -> some View { modifier(GlassBackground(cornerRadius: cornerRadius)) }

    @ViewBuilder func prominentGlassButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.borderedProminent) }
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }

    @ViewBuilder func glassButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { self.buttonStyle(.glass) } else { self.buttonStyle(.bordered) }
        #else
        self.buttonStyle(.bordered)
        #endif
    }
}

struct Card<Content: View>: View {
    var title: String
    var symbol: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    init(_ title: String, symbol: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.trailing = trailing; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                if let trailing { trailing }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

// MARK: - Provenance

struct ProvenanceBadge: View {
    var provenance: Provenance
    var body: some View {
        let (color, symbol) = Self.style(provenance.category)
        Label(provenance.category.label, systemImage: symbol)
            .font(.caption2.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .help(provenance.detail)
            .accessibilityLabel("\(provenance.category.label) : \(provenance.detail)")
    }

    static func style(_ c: Provenance.Category) -> (Color, String) {
        switch c {
        case .measured: return (.green, "checkmark.seal")
        case .router: return (.blue, "wifi.router")
        case .computed: return (.teal, "function")
        case .estimated: return (.orange, "wand.and.stars")
        case .unavailable: return (.secondary, "minus.circle")
        }
    }
}

struct MetricRow<V: Sendable>: View {
    var label: String
    var sourced: Sourced<V>
    var format: (V) -> String
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if let v = sourced.value {
                Text(model.redact(format(v))).monospacedDigit().textSelection(.enabled)
            } else {
                Text("Indisponible").foregroundStyle(.tertiary).help(sourced.provenance.detail)
            }
            ProvenanceBadge(provenance: sourced.provenance)
        }
        .font(.callout)
    }
}

struct KeyValueRow: View {
    var label: String
    var value: String?
    var provenance: Provenance? = nil
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.map(model.redact) ?? "Indisponible")
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .monospacedDigit().textSelection(.enabled).multilineTextAlignment(.trailing)
            if let provenance { ProvenanceBadge(provenance: provenance) }
        }
        .font(.callout)
    }
}

struct BigNumber: View {
    var title: String
    var value: String
    var unit: String = ""
    var subtitle: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(tint)
                if !unit.isEmpty { Text(unit).font(.callout).foregroundStyle(.secondary) }
            }
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.tertiary) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ScoreRing: View {
    var score: Double?
    var size: CGFloat = 120
    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 10)
            if let s = score {
                Circle().trim(from: 0, to: s / 100)
                    .stroke(Self.color(s), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: s)
                Text("\(Int(s.rounded()))").font(.system(size: size * 0.3, weight: .bold, design: .rounded)).monospacedDigit()
            } else {
                Text("—").font(.system(size: size * 0.3, weight: .bold, design: .rounded)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(score.map { "Score \(Int($0)) sur 100" } ?? "Score indisponible")
    }
    static func color(_ s: Double) -> Color { s >= 80 ? .green : (s >= 60 ? .yellow : (s >= 40 ? .orange : .red)) }
}

struct StatusDot: View {
    var color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true) }
}

struct ConfidenceLabel: View {
    var confidence: Confidence
    var body: some View {
        Text("Confiance \(confidence.label.lowercased())")
            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

struct CheckStatusBadge: View {
    var status: CheckStatus
    var body: some View {
        let (c, s): (Color, String) = {
            switch status {
            case .verified: return (.green, "checkmark.shield")
            case .suspect: return (.orange, "exclamationmark.triangle")
            case .notVerified: return (.gray, "questionmark.circle")
            case .unavailable: return (.secondary, "minus.circle")
            }
        }()
        Label(status.rawValue, systemImage: s).font(.caption.weight(.medium)).foregroundStyle(c)
    }
}

struct EmptyStateView: View {
    var title: String
    var symbol: String
    var message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity).padding(32)
    }
}

struct ErrorBanner: View {
    var message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct PageHeader: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.weight(.bold))
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Standard scrolling page layout.
struct Page<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content
    init(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: title, subtitle: subtitle)
                content
            }
            .padding(24)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

extension Date {
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        return f.localizedString(for: self, relativeTo: Date())
    }
    var shortDateTime: String { formatted(date: .abbreviated, time: .shortened) }
}
#endif

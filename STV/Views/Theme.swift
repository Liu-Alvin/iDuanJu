import SwiftUI

/// Dark palette from the PlutoFish mini app. Brand blue marks focus and playback progress.
enum STVTheme {
    static let bg = Color(red: 0.067, green: 0.075, blue: 0.090)
    static let surface = Color(red: 0.110, green: 0.122, blue: 0.145)
    static let elevated = Color(red: 0.224, green: 0.239, blue: 0.259)
    static let text = Color(red: 0.933, green: 0.941, blue: 0.953)
    static let secondary = Color(red: 0.68, green: 0.71, blue: 0.75)
    static let accent = Color(red: 0.541, green: 0.706, blue: 1)
    static let accentWarm = Color(red: 0.949, green: 0.710, blue: 0.361)
    static let glass = text.opacity(0.07)
    static let glassBorder = text.opacity(0.12)
}

struct GlassBackground: ViewModifier {
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.8)
            )
    }
}

extension View {
    func stvGlass(_ radius: CGFloat = 20) -> some View { modifier(GlassBackground(radius: radius)) }
}

struct GlassChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.black.opacity(0.9) : STVTheme.secondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background {
                    if selected {
                        Capsule().fill(STVTheme.text)
                    } else {
                        Capsule().fill(STVTheme.elevated)
                            .overlay(Capsule().strokeBorder(STVTheme.glassBorder, lineWidth: 0.6))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

struct GlassChipBar<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { it in
                    GlassChip(title: label(it), selected: selection == it) { selection = it }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

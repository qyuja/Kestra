import SwiftUI

struct ScreenPositionPicker: View {
    let position: CompletionDisplayPosition
    let onSelect: (CompletionDisplayPosition) -> Void
    private let tint = Color(red: 0.35, green: 0.86, blue: 0.38)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.025))
            ForEach(Array(CompletionDisplayPosition.allCases.enumerated()), id: \.element) { index, candidate in
                let column = index % 3
                let row = index / 3
                Button { onSelect(candidate) } label: {
                    Rectangle()
                        .fill(position == candidate ? tint.opacity(0.25) : Color.white.opacity(0.025))
                        .frame(width: column == 1 ? 124 : 48, height: row == 1 ? 64 : 32)
                        .overlay(Rectangle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: [24.0, 110, 196][column], y: [16.0, 64, 112][row])
                .accessibilityLabel(candidate.title)

            }
            Circle().fill(tint).frame(width: 6, height: 6)
                .shadow(color: tint.opacity(0.7), radius: 4)
                .position(dotPosition)
                .allowsHitTesting(false)
                .animation(.spring(response: 0.32, dampingFraction: 0.75), value: position)
        }
        .frame(width: 220, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.24)))
        .frame(maxWidth: .infinity)
    }

    private var dotPosition: CGPoint {
        let index = CompletionDisplayPosition.allCases.firstIndex(of: position) ?? 4
        return CGPoint(x: [12.0, 110, 208][index % 3], y: [12.0, 64, 116][index / 3])
    }

}

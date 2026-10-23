import AppKit
import SwiftUI

// Shared visual rhythm with Pulldot, using FotoLoop's own warm accent.
enum FLDesign {
    static let canvas = adaptive(light: 0xF5F6F8, dark: 0x17191E)
    static let sidebar = adaptive(light: 0xFFFFFF, dark: 0x212329)
    static let inset = adaptive(light: 0xF0F2F4, dark: 0x191C21)
    static let line = adaptive(light: 0xDEE2E7, dark: 0x383C45)
    static let accent = adaptive(light: 0xB74767, dark: 0xFF91AD)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x231820)
    static let muted = adaptive(light: 0x58616B, dark: 0xA9AFBA)
    static let radius: CGFloat = 12
    static let padding: CGFloat = 22

    private static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct FLChoiceRow<Option: Hashable>: View {
    let title: String
    @Binding var selection: Option
    let choices: [(value: Option, label: String)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(choices.indices, id: \.self) { index in
                let choice = choices[index]
                let selected = selection == choice.value
                Button { selection = choice.value } label: {
                    Text(choice.label)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? FLDesign.accent : Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(selected ? FLDesign.accent.opacity(0.11) : FLDesign.inset,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(selected ? FLDesign.accent.opacity(0.65) : FLDesign.line))
                }
                .buttonStyle(.plain)
                .accessibilityValue(selected ? "Selected" : "Not selected")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct FLNumberRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 4)
            Button { value -= 1 } label: { Image(systemName: "minus") }
                .accessibilityLabel("Decrease \(title.lowercased())")
                .disabled(value <= range.lowerBound)
            Text("\(value)x")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 27)
                .accessibilityLabel("\(title): \(value)")
            Button { value += 1 } label: { Image(systemName: "plus") }
                .accessibilityLabel("Increase \(title.lowercased())")
                .disabled(value >= range.upperBound)
        }
        .buttonStyle(FLControlButtonStyle())
    }
}

private struct FLControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.primary : FLDesign.muted.opacity(0.5))
            .frame(width: 25, height: 25)
            .background(configuration.isPressed ? FLDesign.accent.opacity(0.14) : FLDesign.inset,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(FLDesign.line))
    }
}

struct FLActionButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(!isEnabled ? FLDesign.muted.opacity(0.7) :
                             prominent ? FLDesign.onAccent : Color.primary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(!isEnabled ? FLDesign.inset :
                        prominent ? FLDesign.accent.opacity(configuration.isPressed ? 0.82 : 1) : FLDesign.inset,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(prominent && isEnabled ? Color.clear : FLDesign.line))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

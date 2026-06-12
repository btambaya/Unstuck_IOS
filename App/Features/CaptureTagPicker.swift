// Shared capture-tag chip row (Android's FilterPill row in AddCaptureRow /
// CaptureSheet parity) — used by the task editor's capture composer and the
// focus capture sheet. Five fixed tags, single-select, dot-colored per tag.

import SwiftUI
import UnstuckCore
import UnstuckDesign

struct CaptureTagPicker: View {
    @Binding var selection: CaptureTag
    @Environment(\.uTheme) private var theme

    static let allTags: [CaptureTag] = [.followUp, .idea, .edit, .question, .distraction]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.allTags, id: \.self) { tag in
                    let on = selection == tag
                    Button { selection = tag } label: {
                        HStack(spacing: 5) {
                            Circle().fill(captureTagColor(tag, theme)).frame(width: 6, height: 6)
                            Text(tag.rawValue).font(UFont.sans(12, on ? .semibold : .regular))
                                .foregroundStyle(on ? theme.palette.ink : theme.palette.ink2)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(on ? theme.palette.ink.opacity(0.08) : .clear, in: Capsule())
                        .overlay(Capsule().stroke(theme.palette.line))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Tag → accent color, identical to the Inbox card mapping (Android tagColor).
func captureTagColor(_ tag: CaptureTag, _ theme: UTheme) -> Color {
    switch tag {
    case .followUp: return theme.palette.primaryDeep
    case .idea: return theme.palette.amber
    case .edit: return theme.palette.blue
    case .question: return theme.palette.green
    case .distraction: return theme.palette.coral
    }
}

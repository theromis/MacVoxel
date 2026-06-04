import SwiftUI

// Corner anchors for HUD elements floating over the scene view.
enum HUDCorner {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var alignment: Alignment {
        switch self {
        case .topLeading:     return .topLeading
        case .topTrailing:    return .topTrailing
        case .bottomLeading:  return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
}

// Transparent, full-bleed container meant to sit in `.overlay {}` over the
// Metal scene view. Each registered element is pinned to a corner with a
// uniform inset; the space between elements carries no background, so it is
// not hit-testable and orbit / pan / draw pass straight through to the
// MTKView. Only the controls themselves capture input.
//
// Fiddle by chaining `.corner(_:)`; give each element the floating-card
// look with `.hudPanel()`:
//
//   .overlay {
//       SceneOverlay()
//           .corner(.topTrailing) { MyControls().hudPanel() }
//           .corner(.bottomLeading) { Readout().hudPanel() }
//   }
struct SceneOverlay: View {
    var inset: CGFloat = 12
    private var slots: [(corner: HUDCorner, view: AnyView)] = []

    func corner<Content: View>(_ corner: HUDCorner,
                               @ViewBuilder _ content: () -> Content) -> SceneOverlay {
        var copy = self
        copy.slots.append((corner, AnyView(content())))
        return copy
    }

    var body: some View {
        // No background anywhere: an expanded frame with no fill doesn't
        // capture hits in its empty region, so only the pinned controls
        // intercept the cursor. (Add .contentShape only where you *want*
        // a whole area tappable.)
        ZStack {
            ForEach(slots.indices, id: \.self) { i in
                slots[i].view
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: slots[i].corner.alignment)
            }
        }
        .padding(inset)
    }
}

extension View {
    // Standard floating-HUD chrome: translucent material card, rounded
    // corners, hairline edge, soft drop shadow. Apply to a control before
    // placing it in a SceneOverlay corner.
    func hudPanel(padding: CGFloat = 8, cornerRadius: CGFloat = 10) -> some View {
        self
            .padding(padding)
            .background(.thinMaterial, in: .rect(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
    }
}

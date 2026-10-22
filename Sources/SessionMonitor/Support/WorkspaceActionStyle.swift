import SwiftUI

/// Uses the system's modern action controls, with a native fallback on older Macs.
private struct WorkspaceActionStyle: ViewModifier {
    let prominent: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
            } else {
                content.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
            }
        } else {
            if prominent { content.buttonStyle(.borderedProminent).controlSize(.large) }
            else { content.buttonStyle(.bordered).controlSize(.large) }
        }
    }
}

extension View {
    func workspaceAction(prominent: Bool = false) -> some View {
        modifier(WorkspaceActionStyle(prominent: prominent))
    }
}

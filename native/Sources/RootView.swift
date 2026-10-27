import SwiftUI
import AppKit

struct RootView: View {
    @ObservedObject var state: AppState
    @State private var dragBase: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(state: state)
                .frame(width: state.sidebarWidth)
            MessageListView(state: state)
                .frame(width: state.listWidth)
            resizeHandle
            ReaderPane(state: state)
                .frame(maxWidth: .infinity)
        }
        .environmentObject(state)
        .ignoresSafeArea()
        .background(Palette.elevated)
        .accentColor(Palette.accent)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 5)
            .overlay(Rectangle().fill(Palette.hairline).frame(width: 0.5))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragBase == nil { dragBase = state.listWidth }
                        let base = dragBase ?? state.listWidth
                        state.listWidth = min(Metrics.listMax, max(Metrics.listMin, base + value.translation.width))
                    }
                    .onEnded { _ in dragBase = nil; state.saveLayout() }
            )
    }
}

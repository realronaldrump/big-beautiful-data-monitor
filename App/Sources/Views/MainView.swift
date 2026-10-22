import SwiftUI
import MonitorEngine

extension AppIdentity: @retroactive Identifiable {
    public var id: String { key }
}

/// The main window: Now, Day and Month behind one quiet segmented control.
/// No sidebar, no toolbar, no settings on screen.
struct MainView: View {
    @Bindable var model: MonitorModel

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                switch model.mainTab {
                case .now: NowView()
                case .day: DayView()
                case .month: MonthView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)

            Picker("View", selection: $model.mainTab) {
                ForEach(MainTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 12)
        }
        .animation(.easeInOut(duration: 0.35), value: model.mainTab)
        .sheet(item: $model.detailApp) { identity in
            AppDetailView(identity: identity)
                .environment(model)
                .environment(\.animationsActive, model.isWindowVisible)
                .developmentOverrides()
        }
        .environment(model)
        .environment(\.animationsActive, model.isWindowVisible)
        .developmentOverrides()
        .frame(minWidth: 720, minHeight: 640)
    }
}

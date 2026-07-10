import SwiftUI

struct ScanConfigurator: View {
    @Binding private var task: AlarmTask

    init(task: Binding<AlarmTask>) {
        _task = task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OASpacing.m) {
            Text(L10n.taskScanObjectTitle)
                .font(OAType.sectionLabel)
                .foregroundStyle(OAColor.textPrimary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112), spacing: OASpacing.s)],
                spacing: OASpacing.s
            ) {
                ForEach(ScanObjectCatalog.entries) { entry in
                    Button {
                        task = .scanObject(objectClass: entry.id)
                    } label: {
                        VStack(spacing: OASpacing.xs) {
                            Image(systemName: entry.systemImage)
                                .font(.title3)
                            Text(L10n.taskScanObjectName(entry.id))
                                .font(.caption.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .foregroundStyle(selectedID == entry.id ? OAColor.textPrimary : OAColor.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .padding(OASpacing.xs)
                        .background(
                            selectedID == entry.id ? OAColor.actionCyan.opacity(0.20) : Color.clear,
                            in: RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: OARadius.chip, style: .continuous)
                                .stroke(selectedID == entry.id ? OAColor.actionCyan : OAColor.textSecondary.opacity(0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(OASpacing.m)
        .oaGlassPanel()
        .onAppear(perform: normalizeUnknownSelection)
    }

    private var selectedID: String {
        guard case let .scanObject(objectClass) = task else {
            return ScanObjectCatalog.entries.first?.id ?? ""
        }
        return ScanObjectCatalog.entry(for: objectClass)?.id ?? ScanObjectCatalog.entries.first?.id ?? ""
    }

    private func normalizeUnknownSelection() {
        guard case let .scanObject(objectClass) = task,
              ScanObjectCatalog.entry(for: objectClass) == nil,
              let fallback = ScanObjectCatalog.entries.first
        else {
            return
        }
        task = .scanObject(objectClass: fallback.id)
    }
}

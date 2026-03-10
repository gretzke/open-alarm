import SwiftUI

struct MathSettingsView: View {
    var existingTask: AlarmTask?
    var onAdd: (AlarmTask) -> Void

    @State private var difficulty: MathDifficulty = .simple
    @State private var count: Int = 3

    private let countOptions = [1, 2, 3, 5, 10]

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                ForEach(MathDifficulty.allCases, id: \.self) { diff in
                    Button {
                        difficulty = diff
                    } label: {
                        HStack {
                            Text(diff.displayName)
                                .foregroundStyle(OAColor.textPrimary)
                            Spacer()
                            if difficulty == diff {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(OAColor.actionCyan)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    if diff != MathDifficulty.allCases.last {
                        Divider().overlay(OAColor.glassStroke.opacity(0.8))
                    }
                }
            }
            .oaGlassPanel()

            VStack(spacing: 0) {
                ForEach(countOptions, id: \.self) { option in
                    Button {
                        count = option
                    } label: {
                        HStack {
                            Text(String(localized: "task_math_count \(option)"))
                                .foregroundStyle(OAColor.textPrimary)
                            Spacer()
                            if count == option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(OAColor.actionCyan)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    if option != countOptions.last {
                        Divider().overlay(OAColor.glassStroke.opacity(0.8))
                    }
                }
            }
            .oaGlassPanel()

            Button {
                onAdd(.math(difficulty: difficulty, count: count))
            } label: {
                Text(isEditing
                     ? String(localized: "task_save_button")
                     : String(localized: "task_add_button"))
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.glassProminent)
            .tint(OAColor.actionCyan)

            Spacer()
        }
        .padding()
        .navigationTitle(String(localized: "task_math_name"))
        .onAppear {
            if case .math(let d, let c) = existingTask {
                difficulty = d
                count = c
            }
        }
    }

    private var isEditing: Bool { existingTask != nil }
}

extension MathDifficulty {
    var displayName: String {
        switch self {
        case .simple: String(localized: "task_math_difficulty_simple")
        case .hard: String(localized: "task_math_difficulty_hard")
        }
    }
}

import SwiftUI

struct NapDurationPicker: View {
    @Binding var hours: Int
    @Binding var minutes: Int
    var allowZeroMinutes: Bool = false

    private var minuteOptions: [Int] {
        if hours == 0 {
            return allowZeroMinutes ? Array(0 ... 59) : Array(1 ... 59)
        }

        return Array(0 ... 59)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(L10n.napEditorHoursLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OAColor.textSecondary)

                Picker("", selection: $hours) {
                    ForEach(0 ... 12, id: \.self) { value in
                        Text(value.formatted())
                            .tag(value)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 6) {
                Text(L10n.napEditorMinutesLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OAColor.textSecondary)

                Picker("", selection: $minutes) {
                    ForEach(minuteOptions, id: \.self) { value in
                        if value == 0, allowZeroMinutes, hours == 0 {
                            Text(String(localized: "alarm_editor_snooze_debug_5_seconds")).tag(value)
                        } else {
                            Text(String(format: "%02d", value)).tag(value)
                        }
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if hours == 0, minutes == 0, !allowZeroMinutes {
                minutes = 1
            }
        }
        .onChange(of: hours) { _, newHours in
            if newHours == 0, minutes == 0, !allowZeroMinutes {
                minutes = 1
            }
        }
    }
}

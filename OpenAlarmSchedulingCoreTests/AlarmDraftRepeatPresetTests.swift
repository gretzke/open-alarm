import Testing
@testable import OpenAlarmSchedulingCore

struct AlarmDraftRepeatPresetTests {
    @Test func weekendPresetReplacesMixedSelection() {
        var draft = AlarmDraft(
            repeatDays: [.thursday, .saturday],
            deleteAfterUse: true
        )

        draft.toggleRepeatDaysPreset(AlarmDraft.weekendRepeatDays)

        #expect(draft.repeatDays == [.saturday, .sunday])
        #expect(draft.deleteAfterUse == false)
    }

    @Test func activePresetClearsRepeatDays() {
        var draft = AlarmDraft(
            repeatDays: AlarmDraft.weekendRepeatDays,
            deleteAfterUse: false
        )

        draft.toggleRepeatDaysPreset(AlarmDraft.weekendRepeatDays)

        #expect(draft.repeatDays.isEmpty)
        #expect(draft.deleteAfterUse == false)
    }

    @Test func weekendMatchesOnlyTheExactWeekendSelection() {
        var draft = AlarmDraft(repeatDays: [.saturday, .sunday])

        #expect(draft.repeatDaysMatch(AlarmDraft.weekendRepeatDays))

        draft.toggleRepeatDay(.friday)

        #expect(draft.repeatDaysMatch(AlarmDraft.weekendRepeatDays) == false)
    }

    @Test func everyDayTakesPrecedenceOverOtherPresets() {
        let draft = AlarmDraft(repeatDays: AlarmDraft.everyDayRepeatDays)

        #expect(draft.repeatDaysMatch(AlarmDraft.everyDayRepeatDays))
        #expect(draft.repeatDaysMatch(AlarmDraft.weekdayRepeatDays) == false)
        #expect(draft.repeatDaysMatch(AlarmDraft.weekendRepeatDays) == false)
    }

    @Test func weekdayPresetRequiresMondayThroughFridayExactly() {
        var draft = AlarmDraft(repeatDays: AlarmDraft.weekdayRepeatDays)

        #expect(draft.repeatDaysMatch(AlarmDraft.weekdayRepeatDays))

        draft.toggleRepeatDay(.monday)

        #expect(draft.repeatDaysMatch(AlarmDraft.weekdayRepeatDays) == false)
    }
}

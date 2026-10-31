import Testing
@testable import PluginariumCore

@Test func editMarksDirtyOnlyWhenChanged() {
    var session = EditingSession(saved: .fixture())
    session.edit { _ in }
    #expect(!session.isDirty)
    session.edit { $0.channels.append(.fixture()) }
    #expect(session.isDirty && session.leaveAction == .askToSave)
}

@Test func cleanSessionMayBeLeft() {
    #expect(EditingSession(saved: .fixture()).leaveAction == .proceed)
    #expect(EditingSession(new: .fixture()).leaveAction == .proceed)
}

@Test func presetInSavedConfigurationAsks() {
    #expect(EditingSession(saved: .fixture()).followUpAfterPresetSaved() == .askToSaveConfiguration)
}

@Test func presetInNewConfigurationWaits() {
    #expect(EditingSession(new: .fixture()).followUpAfterPresetSaved() == .keepWithUnsavedConfiguration)
}

@Test func newConfigurationNeedsNameUntilSaved() {
    var session = EditingSession(new: .fixture(name: ""))
    #expect(session.needsName)
    session.configuration.name = "Night"
    session.markSaved()
    #expect(!session.needsName && !session.isDirty)
}

@Test func savedConfigurationNeverNeedsName() {
    #expect(!EditingSession(saved: .fixture()).needsName)
}

@Test func markSavedClearsDirty() {
    var session = EditingSession(saved: .fixture())
    session.edit { $0.name = "Other" }
    session.markSaved()
    #expect(!session.isDirty && session.leaveAction == .proceed)
}

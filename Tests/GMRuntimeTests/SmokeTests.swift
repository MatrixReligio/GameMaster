import Testing
@testable import GMRuntime

@Test func moduleIsPresent() {
    #expect(GMRuntimeModule.name == "GMRuntime")
}

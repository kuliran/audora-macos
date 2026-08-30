import AudoraDomain
import XCTest

final class LibraryAvailabilityTests: XCTestCase {
    func testLibraryAvailabilityCrossesAConcurrencyBoundaryAsAValue() async {
        let availability = await Task.detached {
            LibraryAvailability.noLibrarySelected
        }.value

        XCTAssertEqual(availability, .noLibrarySelected)
    }
}

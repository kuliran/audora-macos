import AudoraContracts
import Foundation
import XCTest

final class ContractResourcesTests: XCTestCase {
    func testEveryContractResourceLoadsFromThePackageBundle() throws {
        for resource in ContractResource.allCases {
            let data = try ContractResources.data(for: resource)
            XCTAssertFalse(data.isEmpty, resource.rawValue)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }
    }
}

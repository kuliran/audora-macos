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

    func testPortableGoldenRootsContainNoMachineLocalAuthority() throws {
        let resources: [ContractResource] = [
            .portableLibraryManifestExample,
            .portableLibraryPreferencesExample,
            .portableProfileNullExample,
            .portableProfileSelectedExample,
        ]
        let forbidden = [
            "bookmark", "absolutePath", "modelPath", "cachePath", "credential",
            "permissionGrant", "hardwareId",
        ]

        for resource in resources {
            let data = try ContractResources.data(for: resource)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            for field in forbidden {
                XCTAssertFalse(text.contains(field), "\(resource.rawValue): \(field)")
            }
        }
    }

    func testProfileHeadSchemaIsASealedNullOrSelectedStructuralUnion() throws {
        let data = try ContractResources.data(for: .profileHeadSchema)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(object["anyOf"])
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(serialized.contains("NullProfileHead"))
        XCTAssertTrue(serialized.contains("SelectedProfileHead"))
        XCTAssertTrue(serialized.contains("unevaluatedProperties"))
    }

    func testChatManifestSchemaSealsNewAndSessionAnalysisCreationShapes() throws {
        let data = try ContractResources.data(for: .chatManifestSchema)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("NewChatManifest"))
        XCTAssertTrue(text.contains("SessionAnalysisChatManifest"))
        XCTAssertTrue(text.contains("originAttachmentId"))
        XCTAssertTrue(text.contains("unevaluatedProperties"))
        XCTAssertTrue(text.contains("creationKind"))
    }

    func testDevelopmentChatGoldenIsCanonicalEmptyAndHasNoMachineAuthority() throws {
        let data = try ContractResources.data(for: .developmentChatExample)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["creationKind"] as? String, "newChat")
        XCTAssertNil(object["originAttachmentId"])
        XCTAssertEqual((object["attachments"] as? [Any])?.count, 0)
        XCTAssertEqual((object["messageIds"] as? [Any])?.count, 0)
        let draft = try XCTUnwrap(object["draft"] as? [String: Any])
        XCTAssertEqual(draft["text"] as? String, "")

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in [
            "bookmark", "absolutePath", "modelPath", "cachePath", "credential",
            "permissionGrant", "hardwareId", "provider", "invocation",
        ] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testEveryDevelopmentChatScenarioForbidsProviderAndAdmissionEffects() throws {
        let resources: [ContractResource] = [
            .createDevelopmentChatScenario,
            .renameDevelopmentChatScenario,
            .filterDevelopmentChatsScenario,
            .relaunchDevelopmentChatScenario,
            .staleRenameDevelopmentChatScenario,
            .wrongLibraryDevelopmentChatScenario,
            .corruptDevelopmentChatScenario,
            .newerDevelopmentChatScenario,
            .collisionDevelopmentChatScenario,
            .providerUnavailableDevelopmentChatScenario,
            .suspendedLibrarySwitchDevelopmentChatScenario,
        ]
        for resource in resources {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: ContractResources.data(for: resource)
                ) as? [String: Any]
            )
            XCTAssertEqual((object["expectedProviderCalls"] as? NSNumber)?.intValue, 0)
            XCTAssertEqual((object["expectedInvocationCalls"] as? NSNumber)?.intValue, 0)
            XCTAssertEqual((object["expectedAdmissionCalls"] as? NSNumber)?.intValue, 0)
        }
    }

    func testDevelopmentChatScenarioSchemaClosesEffectsOutcomesAndNotices() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: ContractResources.data(for: .developmentChatFeatureScenarioSchema)
            ) as? [String: Any]
        )
        let definitions = try XCTUnwrap(object["$defs"] as? [String: Any])
        let event = try XCTUnwrap(
            definitions["DevelopmentChatDependencyEvent"] as? [String: Any]
        )
        let variants = try XCTUnwrap(event["oneOf"] as? [[String: Any]])
        XCTAssertFalse(variants.isEmpty)
        for variant in variants {
            let reference = try XCTUnwrap(variant["$ref"] as? String)
            let name = String(reference.split(separator: "/").last!)
            let shape = try XCTUnwrap(definitions[name] as? [String: Any])
            let properties = try XCTUnwrap(shape["properties"] as? [String: Any])
            let effect = try XCTUnwrap(properties["effect"] as? [String: Any])
            let outcome = try XCTUnwrap(properties["outcome"] as? [String: Any])
            XCTAssertNotNil(effect["const"], name)
            XCTAssertTrue(outcome["const"] != nil || outcome["$ref"] != nil, name)
        }

        let notice = try XCTUnwrap(
            definitions["DevelopmentChatScenarioNotice"] as? [String: Any]
        )
        let noticeVariants = try XCTUnwrap(notice["anyOf"] as? [[String: Any]])
        XCTAssertEqual(noticeVariants.compactMap { $0["const"] as? String }.count, 9)
    }
}

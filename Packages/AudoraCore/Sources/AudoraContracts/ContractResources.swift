import Foundation

public enum ContractResource: String, CaseIterable, Sendable {
    case coachProviderDescriptorSchema = "CoachProviderDescriptor.json"
    case coachRequestSchema = "CoachRequest.json"
    case coachResponseSchema = "CoachResponse.json"
    case libraryFeatureScenarioSchema = "LibraryFeatureScenario.json"
    case readSessionTranscriptsRequestSchema = "ReadSessionTranscriptsRequest.json"
    case readSessionTranscriptsResponseSchema = "ReadSessionTranscriptsResponse.json"
    case libraryLaunchNoSelectionScenario = "library-launch-no-selection.v1.json"
}

public enum ContractResourceError: Error, Equatable, Sendable {
    case missing(ContractResource)
}

public enum ContractResources {
    public static func data(for resource: ContractResource) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: resource.rawValue,
            withExtension: nil
        ) else {
            throw ContractResourceError.missing(resource)
        }

        return try Data(contentsOf: url)
    }
}

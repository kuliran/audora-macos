import Foundation

public enum QualificationFixtureError: Error {
    case missingResource
}

public enum QualificationFixtures {
    public static func responseSchemaData() throws -> Data {
        try resourceData(name: "response-schema", extension: "json")
    }

    public static func syntheticRequestData() throws -> Data {
        try resourceData(name: "synthetic-request", extension: "json")
    }

    private static func resourceData(name: String, extension: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: `extension`) else {
            throw QualificationFixtureError.missingResource
        }
        return try Data(contentsOf: url)
    }
}

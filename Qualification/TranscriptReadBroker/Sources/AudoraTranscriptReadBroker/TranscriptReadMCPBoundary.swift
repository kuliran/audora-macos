import AudoraCodexCLIQualification
import Foundation

public struct TranscriptReadHTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let authority: String
    public let contentType: String
    public let authorization: String?
    public let origin: String?
    public let body: Data

    public init(
        method: String,
        path: String,
        authority: String,
        contentType: String,
        authorization: String?,
        origin: String? = nil,
        body: Data
    ) {
        self.method = method
        self.path = path
        self.authority = authority
        self.contentType = contentType
        self.authorization = authorization
        self.origin = origin
        self.body = body
    }
}

public struct TranscriptReadHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let contentType: String?
    public let body: Data

    init(statusCode: Int, contentType: String?, body: Data) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
    }
}

public enum TranscriptReadMCPClosedReason: String, Equatable, Sendable {
    case transport
    case authorization
    case messageShape
    case protocolState
    case broker
}

/// Strict Streamable-HTTP MCP message boundary for one Attempt. A socket adapter
/// may feed this value type, but no filesystem or generic Library operation is
/// reachable through it.
public actor TranscriptReadMCPBoundary {
    private enum ProtocolState: Equatable {
        case awaitingInitialize
        case initialized
        case stopped
    }

    private let broker: TranscriptReadBroker
    private var capabilityDigest: Data
    private let expectedAuthority: String
    private let maximumBodyBytes: Int
    private var protocolState: ProtocolState = .awaitingInitialize
    private var closedReason: TranscriptReadMCPClosedReason?
    private var receivedInitializedNotification = false

    init(
        broker: TranscriptReadBroker,
        capabilityDigest: Data,
        expectedAuthority: String,
        maximumBodyBytes: Int
    ) {
        self.broker = broker
        self.capabilityDigest = capabilityDigest
        self.expectedAuthority = expectedAuthority
        self.maximumBodyBytes = maximumBodyBytes
    }

    public func handle(_ request: TranscriptReadHTTPRequest) async -> TranscriptReadHTTPResponse {
        guard protocolState != .stopped else {
            return Self.closedResponse(statusCode: 400)
        }
        guard maximumBodyBytes > 0,
              request.body.count <= maximumBodyBytes,
              request.method == "POST",
              request.path == "/mcp",
              request.authority == expectedAuthority,
              isJSONContentType(request.contentType),
              request.origin == nil
        else {
            return await stopWithClosedError(statusCode: 400, reason: .transport)
        }
        guard let capability = parseAuthorization(request.authorization),
              constantTimeEqual(capability.digest, capabilityDigest)
        else {
            return await stopWithClosedError(statusCode: 400, reason: .authorization)
        }
        guard !hasDuplicateObjectKeys(request.body),
              let message = try? JSONSerialization.jsonObject(with: request.body),
              let object = message as? [String: Any],
              object["jsonrpc"] as? String == "2.0",
              let method = object["method"] as? String
        else {
            return await stopWithClosedError(statusCode: 400, reason: .messageShape)
        }

        if method == "notifications/initialized" {
            guard protocolState == .initialized,
                  !receivedInitializedNotification,
                  object["id"] == nil,
                  Set(object.keys).isSubset(of: ["jsonrpc", "method", "params"]),
                  object["params"] == nil
                    || (object["params"] as? [String: Any])?.isEmpty == true
            else {
                return await stopWithClosedError(statusCode: 400, reason: .protocolState)
            }
            receivedInitializedNotification = true
            return TranscriptReadHTTPResponse(statusCode: 202, contentType: nil, body: Data())
        }

        guard let id = canonicalRPCID(object["id"]) else {
            return await stopWithClosedError(statusCode: 400, reason: .messageShape)
        }

        switch method {
        case "initialize":
            guard protocolState == .awaitingInitialize,
                  Set(object.keys).isSubset(of: ["id", "jsonrpc", "method", "params"]),
                  let params = object["params"] as? [String: Any],
                  let protocolVersion = params["protocolVersion"] as? String,
                  ["2025-03-26", "2025-06-18"].contains(protocolVersion),
                  params["capabilities"] is [String: Any],
                  params["clientInfo"] is [String: Any]
            else {
                return await stopWithClosedError(statusCode: 400, reason: .protocolState)
            }
            protocolState = .initialized
            return success(
                id: id,
                result: .object([
                    "capabilities": .object([
                        "tools": .object(["listChanged": .boolean(false)]),
                    ]),
                    "protocolVersion": .string(protocolVersion),
                    "serverInfo": .object([
                        "name": .string("audora-transcript-read"),
                        "version": .string("qualification-v1"),
                    ]),
                ])
            )

        case "ping":
            guard protocolState == .initialized,
                  Set(object.keys).isSubset(of: ["id", "jsonrpc", "method", "params"]),
                  object["params"] == nil || (object["params"] as? [String: Any])?.isEmpty == true
            else {
                return await stopWithClosedError(statusCode: 400, reason: .protocolState)
            }
            return success(id: id, result: .object([:]))

        case "tools/list":
            guard protocolState == .initialized,
                  Set(object.keys).isSubset(of: ["id", "jsonrpc", "method", "params"]),
                  object["params"] == nil || (object["params"] as? [String: Any])?.isEmpty == true
            else {
                return await stopWithClosedError(statusCode: 400, reason: .protocolState)
            }
            return success(
                id: id,
                result: .object([
                    "tools": .array([Self.toolDefinition]),
                ])
            )

        case "tools/call":
            guard protocolState == .initialized,
                  Set(object.keys) == ["id", "jsonrpc", "method", "params"],
                  let params = object["params"] as? [String: Any],
                  Set(params.keys) == ["arguments", "name"],
                  params["name"] as? String == "read_session_transcripts",
                  let arguments = params["arguments"] as? [String: Any],
                  let argumentsData = try? JSONSerialization.data(
                      withJSONObject: arguments,
                      options: [.sortedKeys]
                  )
            else {
                return await stopWithClosedError(statusCode: 400, reason: .protocolState)
            }

            let readResult = await broker.read(
                capability: capability,
                requestBody: argumentsData
            )
            guard case let .delivered(delivery) = readResult,
                  let responseText = String(data: delivery.responseBody, encoding: .utf8)
            else {
                return await stopWithClosedError(statusCode: 400, reason: .broker)
            }
            if delivery.terminatesAttempt {
                stopLocally()
            }
            return success(
                id: id,
                result: .object([
                    "content": .array([
                        .object([
                            "text": .string(responseText),
                            "type": .string("text"),
                        ]),
                    ]),
                    "isError": .boolean(false),
                ])
            )

        default:
            return await stopWithClosedError(statusCode: 400, reason: .protocolState)
        }
    }

    public func stop(reason: TranscriptReadRevocationReason) async {
        guard protocolState != .stopped else { return }
        stopLocally()
        await broker.revoke(reason: reason)
    }

    public func isStopped() -> Bool {
        protocolState == .stopped
    }

    public func diagnosticClosedReason() -> TranscriptReadMCPClosedReason? {
        closedReason
    }

    private func parseAuthorization(_ header: String?) -> TranscriptReadCapability? {
        guard let header,
              header.hasPrefix("Bearer "),
              header.dropFirst("Bearer ".count).contains(" ") == false
        else {
            return nil
        }
        return TranscriptReadCapability(
            bearerValue: String(header.dropFirst("Bearer ".count))
        )
    }

    private func isJSONContentType(_ value: String) -> Bool {
        let parts = value.lowercased().split(separator: ";", omittingEmptySubsequences: false)
        guard parts.first?.trimmingCharacters(in: .whitespaces) == "application/json" else {
            return false
        }
        return parts.dropFirst().allSatisfy {
            $0.trimmingCharacters(in: .whitespaces) == "charset=utf-8"
        }
    }

    private func success(
        id: CanonicalJSONValue,
        result: CanonicalJSONValue
    ) -> TranscriptReadHTTPResponse {
        TranscriptReadHTTPResponse(
            statusCode: 200,
            contentType: "application/json",
            body: CanonicalJSON.serialize(
                .object([
                    "id": id,
                    "jsonrpc": .string("2.0"),
                    "result": result,
                ])
            )
        )
    }

    private func stopWithClosedError(
        statusCode: Int,
        reason: TranscriptReadMCPClosedReason
    ) async -> TranscriptReadHTTPResponse {
        closedReason = reason
        if protocolState != .stopped {
            stopLocally()
            await broker.revoke(reason: .protocolFailure)
        }
        return Self.closedResponse(statusCode: statusCode)
    }

    private static func closedResponse(statusCode: Int) -> TranscriptReadHTTPResponse {
        TranscriptReadHTTPResponse(
            statusCode: statusCode,
            contentType: "application/json",
            body: closedErrorBody
        )
    }

    private func stopLocally() {
        protocolState = .stopped
        capabilityDigest.resetBytes(in: 0 ..< capabilityDigest.count)
        capabilityDigest.removeAll(keepingCapacity: false)
    }

    private static let closedErrorBody = CanonicalJSON.serialize(
        .object([
            "error": .object([
                "code": .integer(-32_600),
                "message": .string("requestRejected"),
            ]),
            "id": .null,
            "jsonrpc": .string("2.0"),
        ])
    )

    private static let toolDefinition: CanonicalJSONValue = .object([
        "description": .string(
            "Atomically returns complete transcripts for one unique nonempty subset of opaque Attempt handles."
        ),
        "inputSchema": .object([
            "$defs": .object([
                "SessionTranscriptHandle": .object([
                    "description": .string("Lowercase canonical UUID text."),
                    "maxLength": .integer(36),
                    "minLength": .integer(36),
                    "pattern": .string(
                        "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
                    ),
                    "type": .string("string"),
                ]),
            ]),
            "$id": .string(
                "https://audora.local/contracts/ReadSessionTranscriptsRequest.json"
            ),
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "properties": .object([
                "sessionTranscriptHandles": .object([
                    "items": .object([
                        "$ref": .string("#/$defs/SessionTranscriptHandle"),
                    ]),
                    "minItems": .integer(1),
                    "type": .string("array"),
                ]),
            ]),
            "required": .array([.string("sessionTranscriptHandles")]),
            "type": .string("object"),
            "unevaluatedProperties": .object([
                "not": .object([:]),
            ]),
        ]),
        "name": .string("read_session_transcripts"),
    ])
}

private func canonicalRPCID(_ value: Any?) -> CanonicalJSONValue? {
    if let string = value as? String, !string.isEmpty, string.utf8.count <= 128 {
        return .string(string)
    }
    if let number = value as? NSNumber,
       !(number is Bool),
       number.doubleValue.isFinite,
       number.doubleValue.rounded(.towardZero) == number.doubleValue
    {
        return .integer(number.int64Value)
    }
    return nil
}

private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
    let count = max(lhs.count, rhs.count)
    for index in 0 ..< count {
        let left = index < lhs.count ? lhs[index] : 0
        let right = index < rhs.count ? rhs[index] : 0
        difference |= left ^ right
    }
    return difference == 0
}

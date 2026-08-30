import "@typespec/json-schema";

using TypeSpec.JsonSchema;

@baseUri("https://audora.local/contracts/")
namespace Audora.Contracts {
  @minLength(1)
  scalar EntityId extends string;

  @minLength(1)
  scalar SessionAttachmentId extends string;

  /** Lowercase canonical UUID text. */
  @minLength(36)
  @maxLength(36)
  @pattern("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
  scalar SessionTranscriptHandle extends string;

  @minLength(1)
  scalar NonEmptyText extends string;
}

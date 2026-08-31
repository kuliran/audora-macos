import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  @pattern("^lib-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar LibraryId extends string;

  @pattern("^prf-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar ProfileRevisionId extends string;

  @pattern("^ses-[0-9]{8}T[0-9]{9}Z-[0-9A-HJKMNP-TV-Z]{4}$")
  scalar SessionId extends string;

  @pattern("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")
  scalar UTCInstant extends string;

  @pattern("^[0-9a-f]{64}$")
  scalar Sha256Hex extends string;

  @minValue(0)
  scalar NonnegativeWholeNumber extends integer;

  @minValue(1)
  scalar PositiveWholeNumber extends integer;

  @jsonSchema
  @id("LibraryManifest.json")
  model LibraryManifest {
    schemaVersion: 1;
    formatName: "audora-library";
    libraryId: LibraryId;
    createdAt: UTCInstant;
    lastSuccessfulMigration: PositiveWholeNumber;
  }

  @jsonSchema
  @id("LibraryPreferences.json")
  model LibraryPreferences {
    schemaVersion: 1;
    language: "en";
    annotationsVisible: boolean;

    @minValueExclusive(0)
    playbackRate: float64;
  }

  model NullProfileHead {
    schemaVersion: 1;
    generation: NonnegativeWholeNumber;
    statementGeneration: NonnegativeWholeNumber;
    updatedAt: UTCInstant;
  }

  model SelectedProfileHead {
    schemaVersion: 1;
    generation: NonnegativeWholeNumber;
    statementGeneration: NonnegativeWholeNumber;
    updatedAt: UTCInstant;
    currentRevisionId: ProfileRevisionId;
    currentRevisionSha256: Sha256Hex;
  }

  @jsonSchema
  @id("ProfileHead.json")
  union ProfileHead {
    nullProfile: NullProfileHead,
    selectedProfile: SelectedProfileHead,
  }
}

import "./portable-library.tsp";
import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  model LibraryScenarioPreferences {
    language: "en";
    annotationsVisible: boolean;

    @minValueExclusive(0)
    playbackRate: float64;
  }

  model LibraryScenarioSnapshot {
    libraryId: LibraryId;
    preferences: LibraryScenarioPreferences;
    profileKind: "null" | "selected";
    statementCount: NonnegativeWholeNumber;
  }

  model LibraryFeatureAwaitingBootstrapState {
    kind: "awaitingBootstrap";
  }

  model LibraryFeatureNoLibrarySelectedState {
    kind: "noLibrarySelected";
    recentAvailable: boolean;
    notice?: string;
  }

  model LibraryFeatureActiveState {
    kind: "active";
    library: LibraryScenarioSnapshot;
    notice?: string;
  }

  model LibraryFeatureReadOnlyState {
    kind: "readOnly";
    libraryId?: LibraryId;
    reason: "newerSchema";
    notice?: string;
  }

  union LibraryFeatureScenarioState {
    awaitingBootstrap: LibraryFeatureAwaitingBootstrapState,
    noLibrarySelected: LibraryFeatureNoLibrarySelectedState,
    active: LibraryFeatureActiveState,
    readOnly: LibraryFeatureReadOnlyState,
  }

  model LibraryFeatureScenarioCommand {
    kind:
      | "start"
      | "create"
      | "chooseExisting"
      | "reopenRecent"
      | "openExternal"
      | "reveal"
      | "close";
    token?: string;
  }

  model LibraryFeatureDependencyEvent {
    port: "libraryWorkspace" | "clock" | "libraryIdGenerator";
    effect: string;
    outcome: string;
    library?: LibraryScenarioSnapshot;
    notice?: string;
  }

  model LibraryFeatureEffect {
    kind: string;
  }

  /** Portable Library lifecycle behavior shared by feature implementations. */
  @jsonSchema
  @id("LibraryFeatureScenario.json")
  model LibraryFeatureScenario {
    schemaVersion: 1;
    scenarioId: string;
    initialState: LibraryFeatureScenarioState;
    command?: LibraryFeatureScenarioCommand;
    commands?: LibraryFeatureScenarioCommand[];
    dependencyTrace: LibraryFeatureDependencyEvent[];
    expectedState: LibraryFeatureScenarioState;
    expectedEffects: LibraryFeatureEffect[];
  }
}

import "@typespec/json-schema";

using TypeSpec.JsonSchema;

namespace Audora.Contracts {
  /** Portable launch behavior shared by feature implementations and runners. */
  @jsonSchema
  @id("LibraryFeatureScenario.json")
  model LibraryFeatureScenario {
    @minValue(1)
    @maxValue(1)
    schemaVersion: int32;

    scenarioId: "library.launch.no-selection";
    initialState: LibraryFeatureAwaitingBootstrapState;
    command: LibraryFeatureStartCommand;

    @minItems(1)
    @maxItems(1)
    dependencyTrace: LibraryFeatureDependencyEvent[];

    expectedState: LibraryFeatureNoLibrarySelectedState;

    @minItems(1)
    @maxItems(1)
    expectedEffects: LibraryFeatureResolveInitialLibraryEffect[];
  }

  model LibraryFeatureAwaitingBootstrapState {
    kind: "awaitingBootstrap";
  }

  model LibraryFeatureStartCommand {
    kind: "start";
  }

  model LibraryFeatureDependencyEvent {
    port: "libraryBootstrap";
    effect: LibraryFeatureResolveInitialLibraryEffect;
    outcome: LibraryFeatureNoLibrarySelectedOutcome;
  }

  model LibraryFeatureNoLibrarySelectedState {
    kind: "noLibrarySelected";
  }

  model LibraryFeatureResolveInitialLibraryEffect {
    kind: "resolveInitialLibrary";
  }

  model LibraryFeatureNoLibrarySelectedOutcome {
    kind: "noLibrarySelected";
  }
}

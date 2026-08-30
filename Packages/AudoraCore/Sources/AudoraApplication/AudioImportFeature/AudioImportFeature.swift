public protocol AudioImportFeature: Sendable {
    func send(_ command: AudioImportCommand) async
    var states: AsyncStream<AudioImportFeatureState> { get }
    var currentState: AudioImportFeatureState { get async }
}

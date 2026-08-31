import AudoraApplication

private func consumePublicCoachContextInterface(
    _ feature: any CoachContextFeature,
    quote: CoachContextQuote,
    outcome: CoachContextQuoteOutcome
) {
    let _: [CoachContextCostCategory: CoachContextComponentCost] = quote.categoryCosts
    let _: CoachTokenEstimateMode = quote.estimatorMode
    _ = feature
    _ = outcome
}

private func quoteChatThroughPublicInterface(
    _ feature: any CoachContextFeature,
    request: CoachContextChatQuoteRequest
) async -> CoachContextQuoteOutcome {
    await feature.quoteChat(request)
}

private func quoteNewChatThroughPublicInterface(
    _ feature: any CoachContextFeature,
    request: CoachContextNewChatQuoteRequest
) async -> ChatCreationQuoteOutcome {
    await feature.quoteNewChat(request)
}

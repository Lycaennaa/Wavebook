import WavebookCore

struct InitialLibraryScanShuffleRequest<Context: Equatable> {
    private var requestedContext: Context?

    mutating func deferUntilScanCompletes(in context: Context) {
        requestedContext = context
    }

    mutating func cancel() {
        requestedContext = nil
    }

    mutating func takeAfterScanCompletes(in context: Context?) -> Bool {
        guard let requestedContext else { return false }
        self.requestedContext = nil
        return requestedContext == context
    }
}

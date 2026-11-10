/// Runs `transform` over `inputs` with at most `width` tasks in flight and returns the results by input.
func concurrentMap<Input: Hashable & Sendable, Output: Sendable>(
    _ inputs: [Input], width: Int, _ transform: @escaping @Sendable (Input) async -> Output
) async -> [Input: Output] {
    await withTaskGroup(of: (Input, Output).self) { group in
        var results: [Input: Output] = [:]
        var iterator = inputs.makeIterator()
        func addNext() -> Bool {
            guard let input = iterator.next() else { return false }
            group.addTask { (input, await transform(input)) }
            return true
        }
        for _ in 0..<max(1, width) where !addNext() { break }
        for await (input, output) in group {
            results[input] = output
            _ = addNext()
        }
        return results
    }
}

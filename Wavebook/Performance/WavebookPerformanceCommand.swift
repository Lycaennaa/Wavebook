import Foundation

@main
enum WavebookPerformanceCommand {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--list-scenarios"] {
            let data = try JSONSerialization.data(withJSONObject: PerformanceScenarios.names, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            return
        }

        guard arguments.count == 2, arguments[0] == "--scenario" else {
            throw PerformanceBenchmarkError.unexpectedResult(
                "Usage: WavebookPerformance --list-scenarios | --scenario NAME"
            )
        }

        let result = try await PerformanceScenarios.run(arguments[1])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(result)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
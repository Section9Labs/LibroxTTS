import Foundation
import PocketBackendBenchmark

@main struct BenchmarkCLI {
    static func main() async {
        do {
            let a = CommandLine.arguments
            guard a.count == 5 else {
                print("pocket-backend-benchmark REQUEST.json ASSETS MODELS OUTPUT"); return
            }
            let request = try JSONDecoder().decode(PocketBackendBenchmark.Request.self, from: Data(contentsOf: URL(fileURLWithPath: a[1])))
            _ = try await PocketBackendBenchmark.run(request, assets: URL(fileURLWithPath: a[2]), models: URL(fileURLWithPath: a[3]), output: URL(fileURLWithPath: a[4]))
        } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
}

import BitMatchTransferCore
import Darwin
import Foundation

@main
struct BitMatchTransferWorkerCommand {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let runtime = TransferWorkerRuntime()

        if arguments == ["capabilities", "--json"] {
            do {
                let data = try TransferWorkerRuntime.makeEncoder().encode(runtime.capabilities())
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
                Darwin.exit(TransferWorkerExitCode.success.rawValue)
            } catch {
                writeError(error.localizedDescription)
                Darwin.exit(TransferWorkerExitCode.internalFailure.rawValue)
            }
        }

        guard arguments.count == 5,
              arguments[0] == "run",
              arguments[1] == "--job",
              arguments[3] == "--evidence" else {
            writeError("Usage: bitmatch-transfer-worker capabilities --json | run --job <job.json> --evidence <evidence.json>")
            Darwin.exit(64)
        }

        do {
            let jobURL = URL(fileURLWithPath: arguments[2])
            let evidenceURL = URL(fileURLWithPath: arguments[4])
            let jobData = try Data(contentsOf: jobURL)
            let job = try TransferWorkerRuntime.makeDecoder().decode(TransferJobSpec.self, from: jobData)
            let result = await runtime.run(job: job, evidenceURL: evidenceURL)
            if let diagnostic = result.diagnostic { writeError(diagnostic) }
            Darwin.exit(result.exitCode.rawValue)
        } catch {
            writeError("Invalid job input: \(error.localizedDescription)")
            Darwin.exit(TransferWorkerExitCode.invalidJob.rawValue)
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

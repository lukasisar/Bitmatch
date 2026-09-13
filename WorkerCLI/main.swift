import BitMatchTransferCore
import Darwin
import Foundation

@main
struct BitMatchTransferWorkerCommand {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let dispatcher = TransferWorkerDispatcher()

        if arguments == ["capabilities", "--json"] {
            do {
                let data = try TransferWorkerRuntime.makeEncoder().encode(dispatcher.capabilities())
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
                Darwin.exit(TransferWorkerExitCode.success.rawValue)
            } catch {
                writeError(error.localizedDescription)
                Darwin.exit(TransferWorkerExitCode.internalFailure.rawValue)
            }
        }

        guard let run = parseRun(arguments) else {
            writeError("Usage: bitmatch-transfer-worker capabilities --json | run --job <job.json> --evidence <evidence.json> [--progress <progress.jsonl>]")
            Darwin.exit(64)
        }
        guard run.jobPath.hasPrefix("/"), run.evidencePath.hasPrefix("/"),
              run.progressPath == nil || run.progressPath!.hasPrefix("/") else {
            writeError("Job, evidence, and progress paths must be absolute")
            Darwin.exit(TransferWorkerExitCode.invalidJob.rawValue)
        }

        do {
            let jobURL = URL(fileURLWithPath: run.jobPath)
            let evidenceURL = URL(fileURLWithPath: run.evidencePath)
            let jobData = try Data(contentsOf: jobURL)
            let job = try TransferWorkerRuntime.makeDecoder().decode(TransferJobSpec.self, from: jobData)

            let progressWriter = run.progressPath.flatMap {
                WorkerLiveProgressSidecar.open(at: URL(fileURLWithPath: $0))
            }
            if run.progressPath != nil, progressWriter == nil {
                writeError("Live progress sidecar could not be opened; continuing because progress is non-authoritative")
            }
            progressWriter?.emitInitialScanning()

            let result: TransferWorkerRunResult
            if let progressWriter {
                result = await OperationProgressObservation.$sink.withValue({ progress in
                    progressWriter.observe(progress)
                }) {
                    await dispatcher.run(job: job, evidenceURL: evidenceURL)
                }
                progressWriter.emitFinishing()
                progressWriter.close()
            } else {
                result = await dispatcher.run(job: job, evidenceURL: evidenceURL)
            }

            if let diagnostic = result.diagnostic { writeError(diagnostic) }
            Darwin.exit(result.exitCode.rawValue)
        } catch {
            writeError("Invalid job input: \(error.localizedDescription)")
            Darwin.exit(TransferWorkerExitCode.invalidJob.rawValue)
        }
    }

    private struct RunArguments {
        let jobPath: String
        let evidencePath: String
        let progressPath: String?
    }

    private static func parseRun(_ arguments: [String]) -> RunArguments? {
        guard arguments.count == 5 || arguments.count == 7,
              arguments.first == "run" else { return nil }

        var values: [String: String] = [:]
        var index = 1
        while index + 1 < arguments.count {
            let key = arguments[index]
            guard ["--job", "--evidence", "--progress"].contains(key), values[key] == nil else {
                return nil
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard let job = values["--job"], let evidence = values["--evidence"] else { return nil }
        return RunArguments(jobPath: job, evidencePath: evidence, progressPath: values["--progress"])
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

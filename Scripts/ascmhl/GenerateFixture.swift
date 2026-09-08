import Foundation
import CryptoKit
@main struct Main {
 static func main() throws {
 let root = URL(fileURLWithPath: CommandLine.arguments[1])
 try FileManager.default.createDirectory(at: root.appendingPathComponent("Camera A"), withIntermediateDirectories: true)
 let data = Data("BitMatch interoperability test\n".utf8)
 try data.write(to: root.appendingPathComponent("Camera A/clip & café.txt"))
 let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
 let url = try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [.init(relativePath: "Camera A/clip & café.txt", size: Int64(data.count), expectedSHA256: sha)], startTime: Date())
 print(url.path)
 }
}

import Foundation
import Testing
@testable import MacViewer

struct MCPRemoteShellTests {
    @Test("Channel replies parse into keyed messages")
    func parsing() {
        let result = MCPRemoteShell.Message(parsing: "MVR-ab12|res|EXIT=0\nhello|world")
        #expect(result?.id == "ab12" && result?.verb == "res" && result?.index == nil)
        #expect(result?.payload == "EXIT=0\nhello|world")
        #expect(result?.key == "ab12|res")

        let ack = MCPRemoteShell.Message(parsing: "MVR-ab12|ack|-1\r\n")
        #expect(ack?.index == -1 && ack?.key == "ab12|ack|-1")

        let chunk = MCPRemoteShell.Message(parsing: "MVR-ab12|chunk|3|7|QUJD")
        #expect(chunk?.index == 3 && chunk?.payload == "7|QUJD" && chunk?.key == "ab12|chunk|3")

        #expect(MCPRemoteShell.Message(parsing: "MVR-ab12|ack|x") == nil)
        #expect(MCPRemoteShell.Message(parsing: "MVR-ab12|bogus|1") == nil)
        #expect(MCPRemoteShell.Message(parsing: "hello") == nil)
        #expect(MCPRemoteShell.isChannelText("#MVRUN-ab12\n$x=1"))
        #expect(!MCPRemoteShell.isChannelText("ordinary copied text"))
    }

    @Test("Exit code is split from command output")
    func results() {
        let ok = MCPRemoteShell.splitResult("EXIT=0\r\nline 1\nline 2\n")
        #expect(ok.exitCode == 0 && ok.output == "line 1\nline 2")
        let failed = MCPRemoteShell.splitResult("EXIT=3\n")
        #expect(failed.exitCode == 3 && failed.output.isEmpty)
        #expect(MCPRemoteShell.splitResult("plain").exitCode == nil)
    }

    @Test("Files survive deflate, base64 and chunking")
    func roundTrip() throws {
        var bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) })
        bytes.append(contentsOf: Array("tiếng Việt\n".utf8))
        let encoded = try MCPRemoteShell.encode(bytes)
        let parts = MCPRemoteShell.chunks(encoded, size: 1_000)
        #expect(parts.allSatisfy { $0.count <= 1_000 })
        #expect(try MCPRemoteShell.decode(parts.joined()) == bytes)
        #expect(try MCPRemoteShell.decode(MCPRemoteShell.encode(Data())) == Data())
        #expect(MCPRemoteShell.chunks("") == [""])
    }

    @Test("The Run-box launcher fits and only runs its own tagged script")
    func launcher() {
        let id = MCPRemoteShell.newID()
        let line = MCPRemoteShell.launcher(id: id)
        #expect(line.count < 259)
        #expect(line.contains("StartsWith('#MVRUN-\(id)')"))
        #expect(MCPRemoteShell.wrapper(id: id, script: "Get-Date").hasPrefix("#MVRUN-\(id)\n"))
    }

    @Test("Paths are quoted for PowerShell and named for saving")
    func paths() {
        let path = "C:\\Users\\John’s 'Files'\\a.txt"
        let script = MCPRemoteShell.putScript(id: "x", remotePath: path, overwrite: false)
        #expect(script.contains(MCPRemoteShell.literal(path)))
        #expect(!script.contains("John"))
        #expect(MCPRemoteShell.fileName(ofRemotePath: "C:\\Users\\An\\logs\\main.log") == "main.log")
        #expect(MCPRemoteShell.fileName(ofRemotePath: "C:\\") == "remote-file")
    }
}

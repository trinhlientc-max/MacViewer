import Foundation

/// A command channel to a Windows computer built only from what an UltraViewer
/// session already offers: the agent's keyboard (Win+R) and the shared
/// clipboard. MacViewer puts a PowerShell script on the remote clipboard, the
/// Run box starts PowerShell to execute it, and the script answers by copying
/// tagged text back. Files travel the same way in deflated base64 chunks, each
/// one acknowledged before the next is sent.
///
/// Every channel text starts with `MVR-<id>|` (or `#MVRUN-<id>` for the script
/// itself) so the session can keep it off this Mac's clipboard.
enum MCPRemoteShell {
    /// Base64 characters per clipboard message; well under the 512K UTF-16 limit.
    static let chunkCharacters = 192_000
    /// Command output kept, from the end, so the reply fits on the clipboard.
    static let outputLimit = 400_000
    static let maxFileBytes = 200 * 1_048_576

    static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
    }

    static func isChannelText(_ text: String) -> Bool {
        text.hasPrefix("MVR-") || text.hasPrefix("#MVRUN-")
    }

    /// A tagged reply from the remote script.
    struct Message: Equatable {
        let id: String
        let verb: String
        /// For `chunk`/`ack`/`next`: the part number. Nil for `res`.
        let index: Int?
        let payload: String

        var key: String { MCPRemoteShell.key(id: id, verb: verb, index: index) }

        /// `MVR-<id>|res|<output>`, `MVR-<id>|ack|<i>`, `MVR-<id>|next|<i>`,
        /// `MVR-<id>|chunk|<i>|<n>|<data>` (payload is `<n>|<data>`).
        init?(parsing text: String) {
            guard text.hasPrefix("MVR-") else { return nil }
            let parts = text.dropFirst(4).split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, !parts[0].isEmpty else { return nil }
            id = String(parts[0])
            verb = String(parts[1])
            let rest = parts.count == 3 ? String(parts[2]) : ""
            switch verb {
            case "res":
                index = nil
                payload = rest
            case "ack", "next":
                guard let value = Int(rest.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
                index = value
                payload = ""
            case "chunk", "put":
                guard let bar = rest.firstIndex(of: "|"), let value = Int(rest[..<bar]) else { return nil }
                index = value
                payload = String(rest[rest.index(after: bar)...])
            default:
                return nil
            }
        }
    }

    static func key(id: String, verb: String, index: Int?) -> String {
        index.map { "\(id)|\(verb)|\($0)" } ?? "\(id)|\(verb)"
    }

    // MARK: Result text

    /// Splits `EXIT=<code>\n<output>` from the wrapper's reply.
    static func splitResult(_ payload: String) -> (exitCode: Int?, output: String) {
        guard payload.hasPrefix("EXIT=") else { return (nil, payload) }
        let line = payload.prefix { !$0.isNewline }
        let code = Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
        let output = payload.dropFirst(line.count).drop { $0.isNewline }
        return (code, String(output).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Files

    static func encode(_ data: Data) throws -> String {
        try (data as NSData).compressed(using: .zlib).base64EncodedString()
    }

    static func decode(_ base64: String) throws -> Data {
        guard let compressed = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if compressed.isEmpty { return Data() }
        return try (compressed as NSData).decompressed(using: .zlib) as Data
    }

    static func chunks(_ text: String, size: Int = chunkCharacters) -> [String] {
        guard !text.isEmpty else { return [""] }
        var result = [String]()
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }

    /// The file name in a Windows (or POSIX) path.
    static func fileName(ofRemotePath path: String) -> String {
        let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
        let safe = name.filter { !":*?\"<>|".contains($0) }
        return safe.isEmpty ? "remote-file" : safe
    }

    // MARK: PowerShell

    /// A PowerShell expression for `text` that no quote character can break
    /// out of (PowerShell also treats ‘ ’ ‚ ‛ as single quotes).
    static func literal(_ text: String) -> String {
        "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(Data(text.utf8).base64EncodedString())'))"
    }

    /// What is typed into the Run box. It runs only a script tagged with this
    /// id, so text the remote person copies in the meantime is never executed.
    static func launcher(id: String) -> String {
        "powershell -NoP -Ep Bypass -W Hidden -C \"$c=Get-Clipboard -Raw;if($c -and $c.StartsWith('#MVRUN-\(id)')){iex $c}\""
    }

    /// Runs `script` and copies `MVR-<id>|res|EXIT=<code>\n<output>` back.
    static func wrapper(id: String, script: String) -> String {
        let encoded = Data(script.utf8).base64EncodedString()
        return """
        #MVRUN-\(id)
        $ProgressPreference='SilentlyContinue'
        $__c=0
        try {
          $__sb=[scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(encoded)')))
          $__o=(& $__sb *>&1 | Out-String -Width 300)
          if ($LASTEXITCODE) { $__c=$LASTEXITCODE }
        } catch { $__o=($_ | Out-String); $__c=1 }
        if (-not $__o) { $__o='' }
        if ($__o.Length -gt \(outputLimit)) { $__o='[... first ' + ($__o.Length-\(outputLimit)) + ' characters cut ...]' + "`n" + $__o.Substring($__o.Length-\(outputLimit)) }
        Set-Clipboard -Value ('MVR-\(id)|res|EXIT=' + $__c + "`n" + $__o)
        """
    }

    /// Receives `MVR-<id>|put|<i>|<n>|<data>` parts and writes the file.
    /// Sends `ack|-1` once ready, then `ack|<i>` after each part.
    static func putScript(id: String, remotePath: String, overwrite: Bool) -> String {
        """
        $p=\(literal(remotePath))
        $id='MVR-\(id)'
        if ((Test-Path -LiteralPath $p -PathType Leaf) -and -not $\(overwrite ? "true" : "false")) { throw "$p already exists. Pass overwrite to replace it." }
        if (Test-Path -LiteralPath $p -PathType Container) { throw "$p is a folder. Give the full file path." }
        $dir=Split-Path -Parent $p
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $ms=New-Object IO.MemoryStream
        $i=0; $n=-1
        Set-Clipboard -Value "$id|ack|-1"
        $t=[DateTime]::UtcNow
        while ($n -lt 0 -or $i -lt $n) {
          $c=Get-Clipboard -Raw
          $pre="$id|put|$i|"
          if ($c -and $c.StartsWith($pre)) {
            $rest=$c.Substring($pre.Length); $k=$rest.IndexOf('|'); $n=[int]$rest.Substring(0,$k)
            $b=[Convert]::FromBase64String($rest.Substring($k+1).Trim()); $ms.Write($b,0,$b.Length)
            Set-Clipboard -Value "$id|ack|$i"; $i++; $t=[DateTime]::UtcNow
          } elseif (([DateTime]::UtcNow-$t).TotalSeconds -gt 60) { throw "Timed out waiting for part $i" }
          else { Start-Sleep -Milliseconds 100 }
        }
        $ms.Position=0
        $ds=New-Object IO.Compression.DeflateStream($ms,[IO.Compression.CompressionMode]::Decompress)
        $fs=[IO.File]::Create($p); $ds.CopyTo($fs); $fs.Close(); $ds.Close()
        "Wrote $p ($((Get-Item -LiteralPath $p).Length) bytes)"
        """
    }

    /// Sends a file as `MVR-<id>|chunk|<i>|<n>|<data>`, waiting for
    /// `MVR-<id>|next|<i>` from this Mac after each part.
    static func getScript(id: String, remotePath: String, chunk: Int = chunkCharacters) -> String {
        """
        $p=\(literal(remotePath))
        $id='MVR-\(id)'
        $C=\(chunk)
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "File not found: $p" }
        if ((Get-Item -LiteralPath $p).Length -gt \(maxFileBytes)) { throw "$p is larger than 200 MB." }
        $fs=[IO.File]::Open($p,'Open','Read','ReadWrite,Delete')
        $ms=New-Object IO.MemoryStream
        $ds=New-Object IO.Compression.DeflateStream($ms,[IO.Compression.CompressionMode]::Compress,$true)
        $fs.CopyTo($ds); $ds.Close(); $fs.Close()
        $s=[Convert]::ToBase64String($ms.ToArray())
        $n=[Math]::Max(1,[int][Math]::Ceiling($s.Length/$C))
        for ($i=0; $i -lt $n; $i++) {
          $len=[Math]::Max(0,[Math]::Min($C,$s.Length-$i*$C))
          Set-Clipboard -Value ("$id|chunk|$i|$n|" + $s.Substring($i*$C,$len))
          $t=[DateTime]::UtcNow
          while ((((Get-Clipboard -Raw) + '').Trim()) -ne "$id|next|$i") {
            if (([DateTime]::UtcNow-$t).TotalSeconds -gt 60) { throw "Timed out after part $i" }
            Start-Sleep -Milliseconds 100
          }
        }
        "Sent $p"
        """
    }
}

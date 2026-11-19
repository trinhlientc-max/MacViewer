import Foundation

/// A command channel to a Windows computer built only from what an UltraViewer
/// session already offers: the agent's keyboard and the shared clipboard.
/// MacViewer opens one visible PowerShell support window (Win+R → `powershell`),
/// starts a small loop in it, then passes each script over the remote clipboard;
/// the window shows the command to the person there and copies tagged text back.
/// Files travel the same way in deflated base64 chunks, each one acknowledged
/// before the next is sent.
///
/// Every channel text starts with `MVR-<id>|` (or `#MVRUN-`/`#MVBOOT-` for
/// scripts) so the session can keep it off this Mac's clipboard.
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
        text.hasPrefix("MVR-") || text.hasPrefix("#MVRUN-") || text.hasPrefix("#MVBOOT-")
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

    // MARK: Support console
    //
    // Commands run in ONE visible PowerShell window per remote session, opened
    // the way a person would (Win+R → `powershell`). Earlier versions typed a
    // hidden `powershell -W Hidden -Ep Bypass … iex (Get-Clipboard)` line into
    // the Run box, which is exactly the "ClickFix" attack Windows Security now
    // blocks, and the person at the computer could not see what was happening.
    // Now the window shows every command with a note in the person's language,
    // asks them to wait, and prints the result, so nothing is hidden.

    /// Typed into the Run box. Nothing else ever goes on that command line.
    static let consoleCommand = "powershell"

    /// Default note shown to the person when the agent gives none.
    static let defaultNote = "Đang chạy lệnh kiểm tra / Running a check"

    /// Typed into the new window: starts the loop placed on the clipboard,
    /// only if it carries this window's tag.
    static func bootLine(sid: String) -> String {
        "$b=Get-Clipboard -Raw; if ($b -and $b.StartsWith('#MVBOOT-\(sid)')) { & ([scriptblock]::Create($b)) }"
    }

    /// The loop running in the support window. It answers `MVR-<sid>|ack|-9`
    /// when ready, then runs each `#MVRUN-<id>@<sid>` command once: it answers
    /// `MVR-<id>|ack|-2` when it picks one up and `MVR-<id>|res|EXIT=<code>\n<output>`
    /// when done. Only commands for its own `sid` run, so text the person
    /// copies is never executed.
    static func consoleScript(sid: String, admin: Bool) -> String {
        """
        #MVBOOT-\(sid)
        $ProgressPreference='SilentlyContinue'
        $__sid='\(sid)'
        # Windows Terminal draws Vietnamese; the classic console's fonts (Lucida
        # Console, raster) do not, so text shown there drops the accents.
        function __t([string]$s) {
          if ($env:WT_SESSION) { return $s }
          $d=$s.Normalize([Text.NormalizationForm]::FormD); $b=New-Object Text.StringBuilder
          foreach ($ch in $d.ToCharArray()) { if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne 'NonSpacingMark') { [void]$b.Append($ch) } }
          ($b.ToString().Normalize([Text.NormalizationForm]::FormC)) -creplace 'đ','d' -creplace 'Đ','D'
        }
        try { $Host.UI.RawUI.WindowTitle='\(admin ? "Hỗ trợ kỹ thuật từ xa (quản trị) - đừng đóng" : "Hỗ trợ kỹ thuật từ xa - đừng đóng")' } catch {}
        Write-Host (__t '')
        Write-Host (__t '  HỖ TRỢ KỸ THUẬT TỪ XA / REMOTE SUPPORT\(admin ? " (QUYỀN QUẢN TRỊ)" : "")') -ForegroundColor Cyan
        Write-Host (__t '  Kỹ thuật viên chạy lệnh kiểm tra và sửa lỗi trong cửa sổ này. Mọi lệnh đều hiện ở đây.') -ForegroundColor Cyan
        Write-Host (__t '  Vui lòng không gõ vào và không đóng cửa sổ này cho tới khi kỹ thuật viên báo xong.') -ForegroundColor Cyan
        Write-Host (__t '  The technician runs checks and fixes here; every command is shown. Closing this window stops them.') -ForegroundColor DarkCyan
        Set-Clipboard -Value "MVR-$__sid|ack|-9"
        $__done=@{}
        while ($true) {
          $__c=$null
          try { $__c=Get-Clipboard -Raw } catch {}
          if (\(admin ? "$false" : "$true") -and $__c -and $__c.StartsWith('#MVBOOT-') -and -not $__c.StartsWith('#MVBOOT-' + $__sid)) {
            Write-Host (__t '')
            Write-Host (__t '  Đã mở cửa sổ hỗ trợ mới, cửa sổ này tự đóng. / A new support window replaced this one.') -ForegroundColor DarkCyan
            Start-Sleep -Seconds 2
            exit
          }
          if ($__c -and $__c.StartsWith('#MVRUN-')) {
            $__l=$__c -split "`r?`n"
            $__h=$__l[0].Trim().Substring(7)
            $__at=$__h.IndexOf('@')
            if ($__at -gt 0 -and $__l.Count -ge 3) {
              $__id=$__h.Substring(0,$__at)
              if ($__h.Substring($__at+1) -eq $__sid -and -not $__done.ContainsKey($__id)) {
                $__done[$__id]=1
                Set-Clipboard -Value "MVR-$__id|ack|-2"
                $__note=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($__l[1].Trim()))
                $__src=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($__l[2].Trim()))
                Write-Host (__t '')
                Write-Host (__t ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $__note)) -ForegroundColor Yellow
                Write-Host (__t '  Vui lòng đợi, đừng đóng cửa sổ này... / Please wait...') -ForegroundColor DarkYellow
                $__sl=@($__src -split "`r?`n" | Where-Object { $_.Trim() })
                $__sl | Select-Object -First 12 | ForEach-Object { Write-Host (__t ('    > ' + $_)) -ForegroundColor DarkGray }
                if ($__sl.Count -gt 12) { Write-Host (__t ('    > ... (+' + ($__sl.Count - 12) + ')')) -ForegroundColor DarkGray }
                $__w=[Diagnostics.Stopwatch]::StartNew()
                $__code=0
                $global:LASTEXITCODE=0
                try {
                  $__o=(& ([scriptblock]::Create($__src)) *>&1 | Out-String -Width 300)
                  if ($global:LASTEXITCODE) { $__code=$global:LASTEXITCODE }
                } catch { $__o=($_ | Out-String); $__code=1 }
                if (-not $__o) { $__o='' }
                @($__o.TrimEnd() -split "`r?`n") | Select-Object -Last 25 | ForEach-Object { Write-Host (__t ('    ' + $_)) -ForegroundColor Gray }
                $__s=[int]$__w.Elapsed.TotalSeconds
                if ($__code -eq 0) { Write-Host (__t ('  Xong (' + $__s + ' giây) / Done')) -ForegroundColor Green }
                else { Write-Host (__t ('  Có lỗi (mã ' + $__code + '), kỹ thuật viên đang xem / Error, being checked')) -ForegroundColor Red }
                if ($__o.Length -gt \(outputLimit)) { $__o='[... first ' + ($__o.Length-\(outputLimit)) + ' characters cut ...]' + "`n" + $__o.Substring($__o.Length-\(outputLimit)) }
                Set-Clipboard -Value ('MVR-' + $__id + '|res|EXIT=' + $__code + "`n" + $__o)
              }
            }
          }
          Start-Sleep -Milliseconds 300
        }
        """
    }

    /// A command for the support window `sid`: tag line, note, script.
    static func command(id: String, sid: String, note: String, script: String) -> String {
        "#MVRUN-\(id)@\(sid)\n\(Data(note.utf8).base64EncodedString())\n\(Data(script.utf8).base64EncodedString())"
    }

    /// Run in the normal support window: saves the loop for `adminSid` as a
    /// script file and opens it in an elevated PowerShell window (UAC prompt).
    static func elevateScript(adminSid: String) -> String {
        """
        $p=Join-Path $env:TEMP 'macviewer-ho-tro-quan-tri.ps1'
        [IO.File]::WriteAllText($p, \(literal(consoleScript(sid: adminSid, admin: true))), (New-Object Text.UTF8Encoding $true))
        Start-Process powershell -Verb RunAs -ArgumentList @('-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $p + '"'))
        'Administrator window requested.'
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

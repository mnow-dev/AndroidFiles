using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace AdbDrive;

/// <summary>A connected adb device (one line of `adb devices -l`).</summary>
public sealed record AdbDevice(string Serial, string State, string Model);

/// <summary>One entry of a device directory listing.</summary>
public sealed class RemoteEntry
{
    public required string Name { get; init; }
    /// <summary>Absolute device path, e.g. /sdcard/DCIM/Camera.</summary>
    public required string Path { get; init; }
    public required bool IsDir { get; init; }
    public required bool IsLink { get; init; }
    public required long Size { get; init; }
    /// <summary>Modification time as reported by toybox ls (device-local, minute resolution).</summary>
    public required DateTime Modified { get; init; }
}

public sealed class AdbException : Exception
{
    public AdbException(string message) : base(message) { }
}

/// <summary>
/// Thin wrapper around the adb CLI. Mirrors lib/src/adb_client.dart.
///
/// Hard-won rules (verified on real hardware, see NOTES.md):
///  - adb escapes separately-passed arguments itself, so the device command
///    must always be passed as ONE string argument.
///  - `adb shell` propagates the device exit code; `adb exec-out` swallows it
///    (always 0), so exec-out is used only for binary streams (cat).
///  - `ls -l` on a symlinked dir shows the link, not contents; append '/'.
///  - Output arrives with \r\n line endings on Windows.
/// </summary>
public sealed class AdbClient
{
    private readonly string _adbPath;

    public AdbClient(string adbPath) => _adbPath = adbPath;

    /// <summary>
    /// Quote an argument for the device-side shell (adb joins shell/exec-out
    /// args with spaces and runs them through /system/bin/sh).
    /// </summary>
    public static string ShellQuote(string s) => "'" + s.Replace("'", "'\\''") + "'";

    private (int ExitCode, string StdOut, string StdErr) Run(
        IReadOnlyList<string> args, int timeoutMs = 30000)
    {
        var psi = new ProcessStartInfo(_adbPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args)
            psi.ArgumentList.Add(a);

        using var p = Process.Start(psi)
            ?? throw new AdbException($"failed to start {_adbPath}");
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(timeoutMs))
        {
            try { p.Kill(entireProcessTree: true); } catch { /* already gone */ }
            throw new AdbException($"adb {string.Join(' ', args)} timed out after {timeoutMs} ms");
        }
        p.WaitForExit(); // flush async output handlers
        return (p.ExitCode, stdout.Result, stderr.Result);
    }

    /// <summary>
    /// Run a command on the device shell. The command must be a single string:
    /// adb escapes separately-passed arguments, so embedded quotes/pipes only
    /// survive when the whole command is one argument. `shell` (unlike
    /// `exec-out`) propagates the device-side exit code.
    /// </summary>
    public (int ExitCode, string StdOut, string StdErr) Shell(
        string serial, string command, int timeoutMs = 30000)
        => Run(["-s", serial, "shell", command], timeoutMs);

    public List<AdbDevice> Devices()
    {
        var (_, stdout, _) = Run(["devices", "-l"], 15000);
        var devices = new List<AdbDevice>();
        foreach (var line in SplitLines(stdout).Skip(1))
        {
            if (line.Trim().Length == 0)
                continue;
            var parts = Regex.Split(line.Trim(), @"\s+");
            if (parts.Length < 2)
                continue;
            var model = parts.FirstOrDefault(p => p.StartsWith("model:"))
                ?.Substring("model:".Length).Replace('_', ' ') ?? "";
            devices.Add(new AdbDevice(parts[0], parts[1], model));
        }
        return devices;
    }

    // toybox ls -lA line format (stable on Android 6+):
    //   drwxrws--x 5 media_rw media_rw 3452 2026-04-07 12:09 Name with spaces
    // Symlinks append " -> target". "total N" lines and error lines don't match.
    private static readonly Regex LsLine = new(
        @"^([bcdlps-][rwxsStT-]{9}\+?)\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s+(.+)$",
        RegexOptions.Compiled);

    /// <summary>
    /// List a directory using toybox ls. Throws AdbListException with a
    /// classified failure kind when the device-side ls fails.
    /// </summary>
    public List<RemoteEntry> List(string serial, string path)
    {
        // Trailing slash makes ls list the contents of symlinked dirs (/sdcard
        // is a symlink to /storage/self/primary) instead of the link itself.
        var target = path.EndsWith('/') ? path : path + "/";
        var (exit, stdout, stderr) = Shell(serial, $"ls -lA {ShellQuote(target)}");
        if (exit != 0)
            throw new AdbListException(ClassifyError(stderr + stdout), $"ls {path} failed: {stderr.Trim()}");

        var entries = new List<RemoteEntry>();
        foreach (var line in SplitLines(stdout))
        {
            var m = LsLine.Match(line);
            if (!m.Success)
                continue; // "total N", char devices, permission errors
            var type = m.Groups[1].Value[0];
            var name = m.Groups[5].Value;
            var isLink = type == 'l';
            if (isLink)
            {
                var arrow = name.IndexOf(" -> ", StringComparison.Ordinal);
                if (arrow != -1)
                    name = name[..arrow];
            }
            if (!DateTime.TryParseExact(
                    $"{m.Groups[3].Value} {m.Groups[4].Value}", "yyyy-MM-dd HH:mm",
                    null, System.Globalization.DateTimeStyles.AssumeLocal, out var mtime))
                mtime = DateTime.Now;
            entries.Add(new RemoteEntry
            {
                Name = name,
                Path = path == "/" ? "/" + name : $"{path.TrimEnd('/')}/{name}",
                // Treat symlinks as directories so /sdcard-style links stay browsable.
                IsDir = type == 'd' || isLink,
                IsLink = isLink,
                Size = long.Parse(m.Groups[2].Value),
                Modified = mtime,
            });
        }
        return entries;
    }

    /// <summary>
    /// Pull a whole file via `adb exec-out cat` (binary-safe) into localPath.
    /// exec-out swallows the device exit code, so success is verified by
    /// comparing the byte count against the size from the directory listing.
    /// </summary>
    public void PullFile(string serial, string devicePath, string localPath, long expectedSize)
    {
        var psi = new ProcessStartInfo(_adbPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in new[] { "-s", serial, "exec-out", $"cat {ShellQuote(devicePath)}" })
            psi.ArgumentList.Add(a);

        using var p = Process.Start(psi)
            ?? throw new AdbException($"failed to start {_adbPath}");
        var stderrTask = p.StandardError.ReadToEndAsync();
        long written;
        using (var f = new FileStream(localPath, FileMode.Create, FileAccess.Write,
                   FileShare.None, 1 << 16))
        {
            p.StandardOutput.BaseStream.CopyTo(f, 1 << 16);
            written = f.Length;
        }
        p.WaitForExit();
        var stderr = stderrTask.Result.Trim();
        if (written != expectedSize)
            throw new AdbException(
                $"pull of {devicePath} produced {written} bytes, expected {expectedSize}" +
                (stderr.Length != 0 ? $" ({stderr})" : ""));
    }

    /// <summary>Filesystem totals for the volume containing path, via df -k.</summary>
    public (ulong TotalBytes, ulong FreeBytes)? DiskFree(string serial, string path)
    {
        try
        {
            var target = path.EndsWith('/') ? path : path + "/";
            var (exit, stdout, _) = Shell(serial, $"df -k {ShellQuote(target)}", 10000);
            if (exit != 0)
                return null;
            // Filesystem 1K-blocks Used Available Use% Mounted on
            var line = SplitLines(stdout).Skip(1).FirstOrDefault(l => l.Trim().Length != 0);
            if (line is null)
                return null;
            var parts = Regex.Split(line.Trim(), @"\s+");
            if (parts.Length < 4
                || !ulong.TryParse(parts[1], out var totalK)
                || !ulong.TryParse(parts[3], out var availK))
                return null;
            return (totalK * 1024, availK * 1024);
        }
        catch (AdbException)
        {
            return null;
        }
    }

    /// <summary>
    /// Push a local file to a device path via `adb push`. Push uses the adb
    /// sync protocol, not the device shell, so the device path is passed as a
    /// plain argument (no shell quoting). Exit codes propagate.
    /// </summary>
    public void Push(string serial, string localPath, string devicePath)
    {
        var size = new System.IO.FileInfo(localPath).Length;
        // Generous timeout: 60 s base + 2 s per MB (worst-case slow USB).
        var timeoutMs = 60_000 + (int)Math.Min(size / (1 << 20) * 2000, 480_000);
        var (exit, stdout, stderr) = Run(["-s", serial, "push", localPath, devicePath], timeoutMs);
        if (exit != 0)
            throw new AdbException($"push to {devicePath} failed: {(stderr + " " + stdout).Trim()}");
    }

    /// <summary>Classify a device-side error message into a failure kind.</summary>
    public static AdbErrorKind ClassifyError(string text) => text switch
    {
        _ when text.Contains("Directory not empty") => AdbErrorKind.DirNotEmpty,
        _ when text.Contains("File exists") => AdbErrorKind.Exists,
        _ when text.Contains("No such file or directory") => AdbErrorKind.NotFound,
        _ when text.Contains("Permission denied") => AdbErrorKind.AccessDenied,
        _ when text.Contains("Not a directory") => AdbErrorKind.NotADirectory,
        _ when text.Contains("not found") || text.Contains("offline") => AdbErrorKind.DeviceGone,
        _ => AdbErrorKind.Other,
    };

    /// <summary>Split adb output into lines, tolerating \r\n (Windows adb).</summary>
    private static IEnumerable<string> SplitLines(string s)
        => s.Split('\n').Select(l => l.TrimEnd('\r'));
}

public enum AdbErrorKind { NotFound, AccessDenied, NotADirectory, DirNotEmpty, Exists, DeviceGone, Other }

public sealed class AdbListException : Exception
{
    public AdbErrorKind Kind { get; }
    public AdbListException(AdbErrorKind kind, string message) : base(message) => Kind = kind;
}

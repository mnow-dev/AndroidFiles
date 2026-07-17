using System.Text.Json;
using Velopack;
using Velopack.Sources;

// A small command-line helper the Flutter app invokes for Velopack updates.
//
//   AndroidFilesUpdater --check     -> one line of JSON on stdout
//   AndroidFilesUpdater --apply     -> download + apply + restart the app
//   AndroidFilesUpdater --version   -> the installed version, or empty
//
// The Flutter exe is the Velopack main application; the install/update hooks
// are dispatched to it, never to this helper. But VelopackApp.Build().Run()
// also initialises the locator that tells UpdateManager where the install is —
// without it, even IsInstalled throws. It is safe to call here: with no hook
// arguments (which this tool never receives) it just sets up the locator and
// returns.
VelopackApp.Build().Run();

const string repoUrl = "https://github.com/mnow-dev/AndroidFiles";

static UpdateManager Manager() =>
    new(new GithubSource(repoUrl, accessToken: null, prerelease: false));

static void EmitCheck(bool available, string? version, string? reason)
{
    var payload = new Dictionary<string, object?> { ["available"] = available };
    if (version != null) payload["version"] = version;
    if (reason != null) payload["reason"] = reason;
    Console.WriteLine(JsonSerializer.Serialize(payload));
}

// "--wait-pid <n>" -> n, or null if absent/malformed.
static int? PidArg(string[] a)
{
    var i = Array.IndexOf(a, "--wait-pid");
    if (i >= 0 && i + 1 < a.Length && int.TryParse(a[i + 1], out var n)) return n;
    return null;
}

static System.Diagnostics.Process? TryGetProcess(int pid)
{
    try { return System.Diagnostics.Process.GetProcessById(pid); }
    catch { return null; }
}

var command = args.Length > 0 ? args[0] : "--help";

try
{
    switch (command)
    {
        case "--check":
        {
            var mgr = Manager();
            if (!mgr.IsInstalled)
            {
                // Running from the dev build / portable ZIP, not a Velopack
                // install. Not an error: there is simply nothing to update.
                EmitCheck(false, null, "not-installed");
                return 0;
            }
            try
            {
                var info = await mgr.CheckForUpdatesAsync();
                if (info == null) EmitCheck(false, null, null);
                else EmitCheck(true, info.TargetFullRelease.Version.ToString(), null);
            }
            catch
            {
                // Offline, rate-limited, or the repo is private (releases/latest
                // 404s unauthenticated). Still a managed install — just can't
                // see releases right now, which is distinct from not-installed.
                EmitCheck(false, null, "check-failed");
            }
            return 0;
        }

        case "--apply":
        {
            var mgr = Manager();
            if (!mgr.IsInstalled)
            {
                Console.Error.WriteLine("not a Velopack install");
                return 3;
            }
            var info = await mgr.CheckForUpdatesAsync();
            if (info == null)
            {
                Console.WriteLine("no-update");
                return 0;
            }
            // Progress is 0..100; print it so the caller can show a bar. The
            // download touches no locked files, so the app stays up for it.
            await mgr.DownloadUpdatesAsync(info, p => Console.WriteLine($"progress {p}"));

            // The app exe and this helper both live in Velopack's current\
            // dir, which the apply step replaces wholesale — so the app has to
            // be gone first. Tell the caller we're ready, wait for it to exit,
            // then apply. (This process survives its parent because Dart does
            // not job-object its children.)
            var waitPid = PidArg(args);
            if (waitPid is int p2)
            {
                Console.WriteLine("ready-to-apply");
                Console.Out.Flush();
                try { TryGetProcess(p2)?.WaitForExit(15000); }
                catch { /* already gone, or never existed — fine */ }
            }

            // Applies the staged update and relaunches the app. Update.exe
            // lives in the parent dir (unlocked) and does the swap; does not
            // return here on success.
            mgr.ApplyUpdatesAndRestart(info);
            return 0;
        }

        case "--version":
        {
            Console.WriteLine(Manager().CurrentVersion?.ToString() ?? "");
            return 0;
        }

        default:
            Console.Error.WriteLine(
                "usage: AndroidFilesUpdater [--check | --apply | --version]");
            return 2;
    }
}
catch (Exception e)
{
    // Never surface a stack trace to the caller; a failed update check must be
    // a quiet no-op, not a crash dialog.
    Console.Error.WriteLine(e.Message);
    return 1;
}

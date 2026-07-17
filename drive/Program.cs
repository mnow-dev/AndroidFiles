using Fsp;

namespace AdbDrive;

/// <summary>
/// AdbDrive — Phase 2 prototype of the AndroidFiles project.
/// Mounts an Android device's /sdcard (over adb) as a read-only Windows
/// drive letter using WinFsp.
/// </summary>
internal static class Program
{
    private const long CacheCapacityBytes = 2L << 30; // ~2 GB

    private static int Main(string[] args)
    {
        string? serial = null;
        var mount = "P:";
        var root = "/sdcard";
        // The app always passes --adb; "adb" (on PATH) is the standalone
        // fallback. Don't hardcode a machine-specific path here.
        var adbPath = "adb";
        var debug = false;
        var writable = false;

        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--serial" when i + 1 < args.Length: serial = args[++i]; break;
                case "--mount" when i + 1 < args.Length: mount = args[++i]; break;
                case "--root" when i + 1 < args.Length: root = args[++i]; break;
                case "--adb" when i + 1 < args.Length: adbPath = args[++i]; break;
                case "--writable": writable = true; break;
                case "--debug": debug = true; break;
                case "--help" or "-h" or "/?":
                    PrintUsage();
                    return 0;
                default:
                    Console.Error.WriteLine($"unknown argument: {args[i]}");
                    PrintUsage();
                    return 2;
            }
        }

        var adb = new AdbClient(adbPath);

        // -------- pick a device
        List<AdbDevice> devices;
        try
        {
            devices = adb.Devices();
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"error: cannot run adb ({adbPath}): {e.Message}");
            return 1;
        }
        var online = devices.Where(d => d.State == "device").ToList();
        AdbDevice? device;
        if (serial is not null)
        {
            device = online.FirstOrDefault(d => d.Serial == serial);
            if (device is null)
            {
                Console.Error.WriteLine($"error: device {serial} not connected " +
                    $"(online: {string.Join(", ", online.Select(d => d.Serial))})");
                return 1;
            }
        }
        else
        {
            device = online.FirstOrDefault();
            if (device is null)
            {
                Console.Error.WriteLine("error: no adb device connected");
                return 1;
            }
        }

        // -------- sanity-check the root before mounting
        try
        {
            adb.List(device.Serial, root);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"error: cannot list {root} on {device.Serial}: {e.Message}");
            return 1;
        }

        // -------- mount
        var cacheDir = Path.Combine(Path.GetTempPath(), "AdbDrive");
        using var cache = new FileCache(cacheDir, CacheCapacityBytes);
        var stageDir = Path.Combine(cacheDir, "stage");
        var fs = new AdbFileSystem(adb, device.Serial, root, cache, writable, stageDir);
        using var host = new FileSystemHost(fs);

        if (debug)
        {
            try { FileSystemHost.SetDebugLogFile("-"); } // stderr
            catch { /* not fatal */ }
        }

        var status = host.Mount(mount, null, false, debug ? unchecked((uint)-1) : 0);
        if (status < 0)
        {
            Console.Error.WriteLine($"error: mount of {mount} failed (NTSTATUS 0x{status:X8}). " +
                "Is WinFsp installed and the drive letter free?");
            return 1;
        }

        var model = device.Model.Length != 0 ? device.Model : device.Serial;
        Console.WriteLine($"AdbDrive: {model} ({device.Serial}) {root} mounted at {host.MountPoint()}");
        Console.WriteLine($"file cache: {cacheDir} (cap {CacheCapacityBytes >> 20} MB, evicted on exit)");
        if (writable)
        {
            Console.WriteLine();
            Console.WriteLine("  *** WRITABLE MODE — changes in Explorer modify the phone ***");
            Console.WriteLine();
            Console.WriteLine("writable volume; press Ctrl+C to unmount");
        }
        else
        {
            Console.WriteLine("read-only volume; press Ctrl+C to unmount");
        }

        using var exit = new ManualResetEventSlim();
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true; // we unmount and exit ourselves
            exit.Set();
        };
        AppDomain.CurrentDomain.ProcessExit += (_, _) => exit.Set();
        exit.Wait();

        Console.WriteLine("unmounting...");
        host.Unmount();
        cache.Dispose();
        Console.WriteLine("done");
        return 0;
    }

    private static void PrintUsage()
    {
        Console.WriteLine("""
            AdbDrive — mount an Android device's storage as a read-only Windows drive.

            usage: AdbDrive [options]
              --serial <serial>   device serial (default: first connected device)
              --mount <point>     mount point, e.g. P: or X: (default: P:)
              --root <path>       device root directory (default: /sdcard)
              --adb <path>        path to adb.exe (default: D:\Dev\tools\platform-tools\adb.exe)
              --writable          DANGEROUS: write-through mode — creating, writing,
                                  renaming, and deleting through the drive modifies
                                  the phone (default: read-only)
              --debug             enable WinFsp debug logging to stderr
            """);
    }
}

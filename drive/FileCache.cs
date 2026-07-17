using System.Security.Cryptography;
using System.Text;

namespace AdbDrive;

/// <summary>
/// Local on-disk cache of pulled device files, with LRU eviction.
///
/// On the first read of a device file the whole file is pulled once via
/// `adb exec-out cat` into %TEMP%\AdbDrive\&lt;hash&gt;.bin and subsequent
/// Read() calls are served from that local file. The cache key includes the
/// file's size and mtime, so a file that changes on the device gets a fresh
/// cache entry. Total size is capped (default 2 GB); least-recently-used
/// entries that have no open handles are evicted first. The whole cache
/// directory is deleted on unmount (Dispose).
/// </summary>
public sealed class FileCache : IDisposable
{
    public sealed class Handle
    {
        internal Entry Entry { get; }
        public FileStream Stream { get; }
        internal Handle(Entry entry, FileStream stream) { Entry = entry; Stream = stream; }
    }

    internal sealed class Entry
    {
        public required string Key { get; init; }
        public required string LocalPath { get; init; }
        public required long Size { get; init; }
        public required string Serial { get; init; }
        public required string SourcePath { get; init; }
        public int OpenCount;          // guarded by cache._gate
        public bool Ready;             // guarded by PullLock (write) / _gate (read)
        public long LastUse;           // guarded by cache._gate
        public readonly object PullLock = new();
    }

    private readonly string _dir;
    private readonly long _capacity;
    private readonly Dictionary<string, Entry> _entries = new();
    private readonly object _gate = new();
    private long _totalBytes;
    private bool _disposed;

    public FileCache(string dir, long capacityBytes)
    {
        _dir = dir;
        _capacity = capacityBytes;
        // Start clean: stale entries from a previous (crashed) run are useless
        // because keys embed size+mtime but nothing tracks their LRU state.
        try { if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true); } catch { }
        Directory.CreateDirectory(_dir);
    }

    /// <summary>
    /// Get a read handle for the given device file, pulling it from the
    /// device first if it is not cached yet. Throws AdbException on pull
    /// failure. Thread-safe; concurrent first-reads pull only once.
    /// </summary>
    public Handle Open(AdbClient adb, string serial, RemoteEntry file)
    {
        var key = HashKey(serial, file);
        Entry entry;
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (!_entries.TryGetValue(key, out entry!))
            {
                entry = new Entry
                {
                    Key = key,
                    LocalPath = Path.Combine(_dir, key + ".bin"),
                    Size = file.Size,
                    Serial = serial,
                    SourcePath = file.Path,
                };
                _entries[key] = entry;
            }
            entry.OpenCount++; // pin before pulling so eviction can't race us
        }

        try
        {
            lock (entry.PullLock)
            {
                if (!entry.Ready)
                {
                    var part = entry.LocalPath + ".part";
                    try
                    {
                        adb.PullFile(serial, file.Path, part, file.Size);
                        File.Move(part, entry.LocalPath, overwrite: true);
                    }
                    catch
                    {
                        try { File.Delete(part); } catch { }
                        throw;
                    }
                    lock (_gate)
                    {
                        entry.Ready = true;
                        _totalBytes += entry.Size;
                        EvictLocked();
                    }
                }
            }
            var stream = new FileStream(entry.LocalPath, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete, 1 << 16);
            lock (_gate)
                entry.LastUse = Environment.TickCount64;
            return new Handle(entry, stream);
        }
        catch
        {
            lock (_gate)
            {
                entry.OpenCount--;
                // Drop a never-completed placeholder so a later retry starts fresh.
                if (!entry.Ready && entry.OpenCount == 0)
                    _entries.Remove(key);
            }
            throw;
        }
    }

    public void Release(Handle handle)
    {
        try { handle.Stream.Dispose(); } catch { }
        lock (_gate)
        {
            handle.Entry.OpenCount--;
            handle.Entry.LastUse = Environment.TickCount64;
        }
    }

    /// <summary>Evict LRU entries with no open handles until under capacity.</summary>
    private void EvictLocked()
    {
        while (_totalBytes > _capacity)
        {
            Entry? victim = null;
            foreach (var e in _entries.Values)
            {
                if (!e.Ready || e.OpenCount != 0)
                    continue;
                if (victim is null || e.LastUse < victim.LastUse)
                    victim = e;
            }
            if (victim is null)
                break; // everything else is in use; allow temporary overshoot
            _entries.Remove(victim.Key);
            _totalBytes -= victim.Size;
            try { File.Delete(victim.LocalPath); } catch { }
        }
    }

    /// <summary>
    /// Drop cached content for a device path (after a mutation through the
    /// writable mode). Entries with open handles are left alone; their keys
    /// (which embed size+mtime) can no longer match a fresh listing anyway.
    /// </summary>
    public void Invalidate(string serial, string devicePath)
    {
        lock (_gate)
        {
            var victims = _entries.Values
                .Where(e => e.Serial == serial && e.SourcePath == devicePath
                            && e.OpenCount == 0 && e.Ready)
                .ToList();
            foreach (var v in victims)
            {
                _entries.Remove(v.Key);
                _totalBytes -= v.Size;
                try { File.Delete(v.LocalPath); } catch { }
            }
        }
    }

    private static string HashKey(string serial, RemoteEntry file)
    {
        var material = $"{serial}|{file.Path}|{file.Size}|{file.Modified:O}";
        return Convert.ToHexStringLower(
            SHA256.HashData(Encoding.UTF8.GetBytes(material)))[..32];
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
                return;
            _disposed = true;
            _entries.Clear();
            _totalBytes = 0;
        }
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }
}

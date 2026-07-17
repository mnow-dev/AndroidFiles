using System.Runtime.InteropServices;
using System.Security.AccessControl;
using Fsp;
using FileInfo = Fsp.Interop.FileInfo;
using VolumeInfo = Fsp.Interop.VolumeInfo;

namespace AdbDrive;

/// <summary>
/// WinFsp filesystem backed by adb: exposes a device directory (default
/// /sdcard) as a Windows volume. Directory listings come from
/// `adb shell ls -lA '&lt;path&gt;/'` and are cached in memory with a short TTL;
/// file contents are pulled whole on first read into a local LRU cache.
///
/// By default the volume is strictly read-only (all mutations rejected with
/// STATUS_MEDIA_WRITE_PROTECTED). With writable=true it implements
/// write-through semantics: writes are staged in a local file and pushed to
/// the device with `adb push` when the handle closes; deletes/renames/mkdir
/// run the corresponding device shell command immediately.
/// </summary>
public sealed class AdbFileSystem : FileSystemBase
{
    private const int DirTtlMs = 10_000;   // successful listings
    private const int NegTtlMs = 3_000;    // failed listings (not found etc.)
    private const int VolInfoTtlMs = 30_000;
    private const int AllocationUnit = 4096;

    private const uint AttrReadOnly = 0x0001;   // FILE_ATTRIBUTE_READONLY
    private const uint AttrDirectory = 0x0010;  // FILE_ATTRIBUTE_DIRECTORY
    private const uint AttrArchive = 0x0020;    // FILE_ATTRIBUTE_ARCHIVE

    // Access rights that would allow modification; in read-only mode, opens
    // requesting any of these are rejected up front so the volume behaves as
    // write-protected.
    private const uint WriteAccessMask =
        0x0002       // FILE_WRITE_DATA
        | 0x0004     // FILE_APPEND_DATA
        | 0x0010     // FILE_WRITE_EA
        | 0x10000    // DELETE
        | 0x40000    // WRITE_DAC
        | 0x80000;   // WRITE_OWNER

    private readonly AdbClient _adb;
    private readonly string _serial;
    private readonly string _root;       // device path, e.g. /sdcard
    private readonly FileCache _cache;
    private readonly bool _writable;
    private readonly string _stageDir;
    private readonly byte[] _defaultSd;
    private readonly ulong _mountTime;

    // Directory listing cache: device path -> snapshot.
    private sealed record CachedDir(long When, List<RemoteEntry>? Entries, int Status);
    private readonly Dictionary<string, CachedDir> _dirCache = new();
    private readonly object[] _dirLocks;

    private (long When, VolumeInfo Info)? _volInfo;
    private readonly object _volLock = new();

    public AdbFileSystem(
        AdbClient adb, string serial, string root, FileCache cache,
        bool writable, string stageDir)
    {
        _adb = adb;
        _serial = serial;
        _root = root.TrimEnd('/');
        if (_root.Length == 0)
            _root = "/";
        _cache = cache;
        _writable = writable;
        _stageDir = stageDir;
        _mountTime = (ulong)DateTime.Now.ToFileTimeUtc();
        _dirLocks = new object[16];
        for (var i = 0; i < _dirLocks.Length; i++)
            _dirLocks[i] = new object();

        // Full access for everyone; in read-only mode write attempts are
        // rejected by the filesystem itself with STATUS_MEDIA_WRITE_PROTECTED,
        // which gives Explorer the friendlier "disk is write-protected"
        // message instead of "access denied".
        var sd = new RawSecurityDescriptor("O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;WD)");
        _defaultSd = new byte[sd.BinaryLength];
        sd.GetBinaryForm(_defaultSd, 0);
    }

    /// <summary>Per-open context object (used as WinFsp FileDesc).</summary>
    private sealed class FileDesc
    {
        public required RemoteEntry Entry;
        public required FileInfo Info;
        public List<(string Name, FileInfo Info)>? DirSnapshot;
        public FileCache.Handle? CacheHandle;
        // Writable mode: local staging copy that receives writes and is
        // pushed to the device when the handle closes.
        public string? StagePath;
        public FileStream? Stage;
        public bool Dirty;    // staging content differs from device
        public bool Deleted;  // delete-on-close executed; skip push
        public readonly object Lock = new();
    }

    // ---------------------------------------------------------------- setup

    public override int Init(object Host0)
    {
        var host = (FileSystemHost)Host0;
        host.SectorSize = AllocationUnit;
        host.SectorsPerAllocationUnit = 1;
        host.MaxComponentLength = 255;
        // Writable mode keeps kernel metadata caching short so mutations
        // become visible quickly; read-only can cache as long as we do.
        host.FileInfoTimeout = _writable ? 1000u : DirTtlMs;
        host.CaseSensitiveSearch = true;      // Android storage is case-sensitive
        host.CasePreservedNames = true;
        host.UnicodeOnDisk = true;
        host.PersistentAcls = false;
        host.PostCleanupWhenModifiedOnly = true;
        // Writable: make the FSD flush the Windows cache into Write() before
        // Cleanup is delivered, so push-on-cleanup sees the complete file.
        // (IRP_MJ_CLOSE can be deferred by the cache manager for a long time,
        // so pushing only on Close would leave the device stale for minutes.)
        host.FlushAndPurgeOnCleanup = _writable;
        host.VolumeCreationTime = _mountTime;
        host.VolumeSerialNumber = (uint)_serial.GetHashCode();
        host.FileSystemName = "AdbFS";
        return STATUS_SUCCESS;
    }

    public override int GetVolumeInfo(out VolumeInfo volumeInfo)
    {
        lock (_volLock)
        {
            var now = Environment.TickCount64;
            if (_volInfo is { } cached && now - cached.When < VolInfoTtlMs)
            {
                volumeInfo = cached.Info;
                return STATUS_SUCCESS;
            }
            var vi = default(VolumeInfo);
            var df = _adb.DiskFree(_serial, _root);
            vi.TotalSize = df?.TotalBytes ?? 1UL << 40;
            vi.FreeSize = df?.FreeBytes ?? 0;
            vi.SetVolumeLabel("Android");
            _volInfo = (now, vi);
            volumeInfo = vi;
            return STATUS_SUCCESS;
        }
    }

    // ------------------------------------------------------------- lookups

    /// <summary>Map a WinFsp file name ("\DCIM\Camera") to a device path.</summary>
    private string DevicePath(string fileName)
        => fileName == "\\" ? _root : _root + fileName.Replace('\\', '/');

    private static int MapKind(AdbErrorKind kind) => kind switch
    {
        AdbErrorKind.NotFound => STATUS_OBJECT_NAME_NOT_FOUND,
        AdbErrorKind.AccessDenied => STATUS_ACCESS_DENIED,
        AdbErrorKind.NotADirectory => STATUS_NOT_A_DIRECTORY,
        AdbErrorKind.DirNotEmpty => STATUS_DIRECTORY_NOT_EMPTY,
        AdbErrorKind.Exists => STATUS_OBJECT_NAME_COLLISION,
        AdbErrorKind.DeviceGone => STATUS_DEVICE_NOT_READY,
        _ => STATUS_IO_DEVICE_ERROR,
    };

    /// <summary>
    /// Get the (possibly cached) listing of a device directory.
    /// Returns an NTSTATUS; entries is non-null on success.
    /// </summary>
    private int GetListing(string devicePath, out List<RemoteEntry>? entries)
    {
        var now = Environment.TickCount64;
        lock (_dirCache)
        {
            if (_dirCache.TryGetValue(devicePath, out var c)
                && now - c.When < (c.Status == STATUS_SUCCESS ? DirTtlMs : NegTtlMs))
            {
                entries = c.Entries;
                return c.Status;
            }
        }
        // Per-path striped lock so one slow adb call doesn't serialize everything
        // but concurrent requests for the same path fetch only once.
        var gate = _dirLocks[(uint)devicePath.GetHashCode() % _dirLocks.Length];
        lock (gate)
        {
            lock (_dirCache)
            {
                if (_dirCache.TryGetValue(devicePath, out var c)
                    && Environment.TickCount64 - c.When < (c.Status == STATUS_SUCCESS ? DirTtlMs : NegTtlMs))
                {
                    entries = c.Entries;
                    return c.Status;
                }
            }
            int status;
            List<RemoteEntry>? list = null;
            try
            {
                list = _adb.List(_serial, devicePath);
                status = STATUS_SUCCESS;
            }
            catch (AdbListException e)
            {
                status = MapKind(e.Kind);
            }
            catch (AdbException)
            {
                status = STATUS_IO_DEVICE_ERROR;
            }
            lock (_dirCache)
                _dirCache[devicePath] = new CachedDir(Environment.TickCount64, list, status);
            entries = list;
            return status;
        }
    }

    /// <summary>
    /// After a successful mutation: drop the parent directory's cached
    /// listing (and the path's own, if it was a directory) plus any pulled
    /// content for the path.
    /// </summary>
    private void InvalidateAfterMutation(string devicePath)
    {
        var slash = devicePath.LastIndexOf('/');
        var parent = slash <= 0 ? "/" : devicePath[..slash];
        lock (_dirCache)
        {
            _dirCache.Remove(parent);
            _dirCache.Remove(devicePath);
        }
        _cache.Invalidate(_serial, devicePath);
    }

    /// <summary>Run a device shell mutation command, mapping errors to NTSTATUS.</summary>
    private int ShellOp(string command)
    {
        try
        {
            var (exit, stdout, stderr) = _adb.Shell(_serial, command);
            if (exit == 0)
                return STATUS_SUCCESS;
            if (exit == 17)
                return STATUS_OBJECT_NAME_COLLISION; // our exists-probe convention
            return MapKind(AdbClient.ClassifyError(stderr + stdout));
        }
        catch (AdbException)
        {
            return STATUS_IO_DEVICE_ERROR;
        }
    }

    private RemoteEntry RootEntry() => new()
    {
        Name = "",
        Path = _root,
        IsDir = true,
        IsLink = false,
        Size = 0,
        Modified = DateTime.FromFileTimeUtc((long)_mountTime).ToLocalTime(),
    };

    /// <summary>Resolve a WinFsp file name to a RemoteEntry via its parent's listing.</summary>
    private int LookupEntry(string fileName, out RemoteEntry? entry)
    {
        entry = null;
        if (fileName == "\\" || fileName.Length == 0)
        {
            entry = RootEntry();
            return STATUS_SUCCESS;
        }
        var slash = fileName.LastIndexOf('\\');
        var parent = slash == 0 ? "\\" : fileName[..slash];
        var name = fileName[(slash + 1)..];
        var status = GetListing(DevicePath(parent), out var list);
        if (status != STATUS_SUCCESS)
            return status == STATUS_OBJECT_NAME_NOT_FOUND
                ? STATUS_OBJECT_PATH_NOT_FOUND
                : status;
        entry = list!.Find(e => string.Equals(e.Name, name, StringComparison.Ordinal));
        return entry is not null ? STATUS_SUCCESS : STATUS_OBJECT_NAME_NOT_FOUND;
    }

    private FileInfo MakeFileInfo(RemoteEntry e)
    {
        var time = (ulong)e.Modified.ToFileTimeUtc();
        var size = e.IsDir ? 0UL : (ulong)e.Size;
        var attrs = e.IsDir ? AttrDirectory : AttrArchive;
        if (!_writable)
            attrs |= AttrReadOnly;
        return new FileInfo
        {
            FileAttributes = attrs,
            FileSize = size,
            AllocationSize = (size + AllocationUnit - 1) / AllocationUnit * AllocationUnit,
            CreationTime = time,
            LastAccessTime = time,
            LastWriteTime = time,
            ChangeTime = time,
        };
    }

    /// <summary>Current FileInfo for an open, honoring the staging file's size. Caller holds fd.Lock.</summary>
    private FileInfo InfoLocked(FileDesc fd)
    {
        var info = MakeFileInfo(fd.Entry);
        if (fd.Stage is not null)
        {
            var size = (ulong)fd.Stage.Length;
            info.FileSize = size;
            info.AllocationSize = (size + AllocationUnit - 1) / AllocationUnit * AllocationUnit;
        }
        fd.Info = info;
        return info;
    }

    /// <summary>
    /// Ensure the open has a local staging file (writable mode). When
    /// pullExisting is set and the device file has content, the staging file
    /// starts as a copy of the device content (via the read cache).
    /// Caller holds fd.Lock.
    /// </summary>
    private void EnsureStageLocked(FileDesc fd, bool pullExisting)
    {
        if (fd.Stage is not null)
            return;
        Directory.CreateDirectory(_stageDir);
        fd.StagePath = Path.Combine(_stageDir, Guid.NewGuid().ToString("N"));
        if (pullExisting && fd.Entry.Size > 0)
        {
            var handle = _cache.Open(_adb, _serial, fd.Entry);
            try
            {
                using var dst = new FileStream(fd.StagePath, FileMode.CreateNew, FileAccess.Write);
                lock (handle.Stream)
                {
                    handle.Stream.Position = 0;
                    handle.Stream.CopyTo(dst);
                }
            }
            finally
            {
                _cache.Release(handle);
            }
        }
        fd.Stage = new FileStream(fd.StagePath, FileMode.OpenOrCreate,
            FileAccess.ReadWrite, FileShare.Read);
    }

    /// <summary>Push the staging file to the device. Caller holds fd.Lock. Throws AdbException.</summary>
    private void PushStageLocked(FileDesc fd)
    {
        fd.Stage!.Flush();
        _adb.Push(_serial, fd.StagePath!, fd.Entry.Path);
        fd.Dirty = false;
        InvalidateAfterMutation(fd.Entry.Path);
    }

    // ------------------------------------------------------------ open/close

    public override int GetSecurityByName(
        string fileName, out uint fileAttributes, ref byte[] securityDescriptor)
    {
        var status = LookupEntry(fileName, out var entry);
        if (status != STATUS_SUCCESS)
        {
            fileAttributes = default;
            return status;
        }
        fileAttributes = MakeFileInfo(entry!).FileAttributes;
        if (securityDescriptor is not null)
            securityDescriptor = _defaultSd;
        return STATUS_SUCCESS;
    }

    public override int Open(
        string fileName, uint createOptions, uint grantedAccess,
        out object fileNode, out object fileDesc,
        out FileInfo fileInfo, out string normalizedName)
    {
        fileNode = null!;
        fileDesc = null!;
        fileInfo = default;
        normalizedName = null!;

        if (!_writable && (grantedAccess & WriteAccessMask) != 0)
            return STATUS_MEDIA_WRITE_PROTECTED;

        var status = LookupEntry(fileName, out var entry);
        if (status != STATUS_SUCCESS)
            return status;

        if (entry!.IsDir && (createOptions & FILE_NON_DIRECTORY_FILE) != 0)
            return STATUS_FILE_IS_A_DIRECTORY;
        if (!entry.IsDir && (createOptions & FILE_DIRECTORY_FILE) != 0)
            return STATUS_NOT_A_DIRECTORY;

        var info = MakeFileInfo(entry);
        fileDesc = new FileDesc { Entry = entry, Info = info };
        fileInfo = info;
        normalizedName = fileName; // case-sensitive volume: names are exact
        return STATUS_SUCCESS;
    }

    public override int Create(
        string fileName, uint createOptions, uint grantedAccess, uint fileAttributes,
        byte[] securityDescriptor, ulong allocationSize,
        out object fileNode, out object fileDesc,
        out FileInfo fileInfo, out string normalizedName)
    {
        fileNode = null!;
        fileDesc = null!;
        fileInfo = default;
        normalizedName = null!;
        if (!_writable)
            return STATUS_MEDIA_WRITE_PROTECTED;

        var devPath = DevicePath(fileName);
        var isDir = (createOptions & FILE_DIRECTORY_FILE) != 0;
        var q = AdbClient.ShellQuote(devPath);
        // The file is created on the device immediately so it is visible to
        // lookups/enumeration; content follows on close via push. The
        // exists-probe (exit 17 -> collision) covers stale-cache races: the
        // FSD only calls Create after GetSecurityByName reported not-found.
        var status = ShellOp(isDir
            ? $"mkdir {q}"
            : $"if [ -e {q} ]; then exit 17; else touch {q}; fi");
        if (status != STATUS_SUCCESS)
            return status;
        InvalidateAfterMutation(devPath);

        var entry = new RemoteEntry
        {
            Name = fileName[(fileName.LastIndexOf('\\') + 1)..],
            Path = devPath,
            IsDir = isDir,
            IsLink = false,
            Size = 0,
            Modified = DateTime.Now,
        };
        var info = MakeFileInfo(entry);
        var fd = new FileDesc { Entry = entry, Info = info };
        if (!isDir)
        {
            try
            {
                lock (fd.Lock)
                    EnsureStageLocked(fd, pullExisting: false);
            }
            catch (Exception e) when (e is AdbException or IOException)
            {
                return STATUS_IO_DEVICE_ERROR;
            }
        }
        fileDesc = fd;
        fileInfo = info;
        normalizedName = fileName;
        return STATUS_SUCCESS;
    }

    public override int Overwrite(
        object fileNode, object fileDesc0, uint fileAttributes,
        bool replaceFileAttributes, ulong allocationSize, out FileInfo fileInfo)
    {
        fileInfo = default;
        if (!_writable)
            return STATUS_MEDIA_WRITE_PROTECTED;
        var fd = (FileDesc)fileDesc0;
        try
        {
            lock (fd.Lock)
            {
                EnsureStageLocked(fd, pullExisting: false); // overwrite: start empty
                fd.Stage!.SetLength(0);
                fd.Dirty = true;
                fileInfo = InfoLocked(fd);
            }
            return STATUS_SUCCESS;
        }
        catch (Exception e) when (e is AdbException or IOException)
        {
            return STATUS_IO_DEVICE_ERROR;
        }
    }

    public override void Cleanup(object fileNode, object fileDesc0, string fileName, uint flags)
    {
        if (!_writable)
            return;
        var fd = (FileDesc)fileDesc0;

        if ((flags & CleanupDelete) != 0)
        {
            lock (fd.Lock)
                fd.Deleted = true;
            var path = fd.Entry.Path;
            // rmdir (never rm -rf) so non-empty directories fail, matching
            // Windows semantics; rm -f for files.
            var status = ShellOp(fd.Entry.IsDir
                ? $"rmdir {AdbClient.ShellQuote(path)}"
                : $"rm -f {AdbClient.ShellQuote(path)}");
            if (status != STATUS_SUCCESS)
                Console.Error.WriteLine($"AdbDrive: delete of {path} failed (0x{status:X8})");
            InvalidateAfterMutation(path);
            return;
        }

        // Push-on-cleanup: FlushAndPurgeOnCleanup guarantees the Windows
        // cache has been flushed into Write() by now, so the staging file is
        // complete. (IRP_MJ_CLOSE can be deferred arbitrarily by the cache
        // manager, so Close alone would push far too late.)
        lock (fd.Lock)
        {
            if (fd.Stage is not null && fd.Dirty && !fd.Deleted)
            {
                try
                {
                    PushStageLocked(fd);
                }
                catch (Exception e)
                {
                    Console.Error.WriteLine(
                        $"AdbDrive: PUSH FAILED, device copy of {fd.Entry.Path} is stale/incomplete: {e.Message}");
                }
            }
        }
    }

    public override void Close(object fileNode, object fileDesc0)
    {
        var fd = (FileDesc)fileDesc0;
        FileCache.Handle? handle;
        FileStream? stage;
        string? stagePath;
        lock (fd.Lock)
        {
            handle = fd.CacheHandle;
            fd.CacheHandle = null;
            fd.DirSnapshot = null;
            // Push-on-close: write-through happens here. Windows cannot
            // surface errors from CloseHandle, so failures are logged; apps
            // that need confirmation can FlushFileBuffers, which pushes and
            // does return a status.
            if (fd.Stage is not null && fd.Dirty && !fd.Deleted)
            {
                try
                {
                    PushStageLocked(fd);
                }
                catch (Exception e)
                {
                    Console.Error.WriteLine(
                        $"AdbDrive: PUSH FAILED, device copy of {fd.Entry.Path} is stale/incomplete: {e.Message}");
                }
            }
            stage = fd.Stage;
            stagePath = fd.StagePath;
            fd.Stage = null;
            fd.StagePath = null;
        }
        if (handle is not null)
            _cache.Release(handle);
        if (stage is not null)
        {
            try { stage.Dispose(); } catch { }
            try { File.Delete(stagePath!); } catch { }
        }
    }

    public override int GetFileInfo(object fileNode, object fileDesc0, out FileInfo fileInfo)
    {
        var fd = (FileDesc)fileDesc0;
        lock (fd.Lock)
            fileInfo = InfoLocked(fd);
        return STATUS_SUCCESS;
    }

    // ------------------------------------------------------------ read/write

    public override int Read(
        object fileNode, object fileDesc0, IntPtr buffer,
        ulong offset, uint length, out uint bytesTransferred)
    {
        bytesTransferred = 0;
        var fd = (FileDesc)fileDesc0;
        if (fd.Entry.IsDir)
            return STATUS_INVALID_DEVICE_REQUEST;

        // A staged open reads its own (possibly modified) local copy.
        lock (fd.Lock)
        {
            if (fd.Stage is { } stage)
            {
                if (offset >= (ulong)stage.Length)
                    return STATUS_END_OF_FILE;
                var want = (int)Math.Min(length, (ulong)stage.Length - offset);
                var staged = new byte[want];
                stage.Position = (long)offset;
                var got = 0;
                while (got < want)
                {
                    var n = stage.Read(staged, got, want - got);
                    if (n == 0)
                        break;
                    got += n;
                }
                if (got == 0)
                    return STATUS_END_OF_FILE;
                Marshal.Copy(staged, 0, buffer, got);
                bytesTransferred = (uint)got;
                return STATUS_SUCCESS;
            }
        }

        if (offset >= (ulong)fd.Entry.Size)
            return STATUS_END_OF_FILE;

        FileCache.Handle handle;
        try
        {
            lock (fd.Lock)
            {
                // First read of this open: ensure the file is in the local
                // cache (pulls the whole file from the device once, globally).
                fd.CacheHandle ??= _cache.Open(_adb, _serial, fd.Entry);
                handle = fd.CacheHandle;
            }
        }
        catch (AdbException)
        {
            return STATUS_IO_DEVICE_ERROR;
        }

        var chunk = new byte[length];
        int read;
        lock (handle.Stream)
        {
            handle.Stream.Position = (long)offset;
            read = 0;
            while (read < chunk.Length)
            {
                var n = handle.Stream.Read(chunk, read, chunk.Length - read);
                if (n == 0)
                    break;
                read += n;
            }
        }
        if (read == 0)
            return STATUS_END_OF_FILE;
        Marshal.Copy(chunk, 0, buffer, read);
        bytesTransferred = (uint)read;
        return STATUS_SUCCESS;
    }

    public override int Write(
        object fileNode, object fileDesc0, IntPtr buffer, ulong offset, uint length,
        bool writeToEndOfFile, bool constrainedIo,
        out uint bytesTransferred, out FileInfo fileInfo)
    {
        bytesTransferred = 0;
        fileInfo = default;
        if (!_writable)
            return STATUS_MEDIA_WRITE_PROTECTED;
        var fd = (FileDesc)fileDesc0;
        if (fd.Entry.IsDir)
            return STATUS_INVALID_DEVICE_REQUEST;
        try
        {
            lock (fd.Lock)
            {
                EnsureStageLocked(fd, pullExisting: true);
                var stage = fd.Stage!;
                var fileSize = (ulong)stage.Length;
                if (constrainedIo)
                {
                    // Paging I/O must not grow the file.
                    if (offset >= fileSize)
                    {
                        fileInfo = InfoLocked(fd);
                        return STATUS_SUCCESS;
                    }
                    if (offset + length > fileSize)
                        length = (uint)(fileSize - offset);
                }
                else if (writeToEndOfFile)
                {
                    offset = fileSize;
                }
                var chunk = new byte[length];
                Marshal.Copy(buffer, chunk, 0, (int)length);
                stage.Position = (long)offset;
                stage.Write(chunk, 0, (int)length);
                fd.Dirty = true;
                bytesTransferred = length;
                fileInfo = InfoLocked(fd);
            }
            return STATUS_SUCCESS;
        }
        catch (Exception e) when (e is AdbException or IOException)
        {
            return STATUS_IO_DEVICE_ERROR;
        }
    }

    public override int Flush(object fileNode, object fileDesc0, out FileInfo fileInfo)
    {
        fileInfo = default;
        if (fileDesc0 is not FileDesc fd)
            return STATUS_SUCCESS; // volume flush
        if (!_writable)
        {
            fileInfo = fd.Info;
            return STATUS_SUCCESS; // nothing to flush on a read-only volume
        }
        lock (fd.Lock)
        {
            if (fd.Stage is not null && fd.Dirty && !fd.Deleted)
            {
                try
                {
                    PushStageLocked(fd); // explicit flush: surface push errors
                }
                catch (Exception e)
                {
                    Console.Error.WriteLine($"AdbDrive: flush-push of {fd.Entry.Path} failed: {e.Message}");
                    return STATUS_IO_DEVICE_ERROR;
                }
            }
            fileInfo = InfoLocked(fd);
        }
        return STATUS_SUCCESS;
    }

    public override int SetBasicInfo(
        object fileNode, object fileDesc0, uint fileAttributes,
        ulong creationTime, ulong lastAccessTime, ulong lastWriteTime, ulong changeTime,
        out FileInfo fileInfo)
    {
        fileInfo = default;
        if (!_writable)
            return STATUS_MEDIA_WRITE_PROTECTED;
        // Accepted but not persisted: Android's FUSE storage controls mtime on
        // push and has no creation time. Failing this would break Explorer
        // copies, which always set timestamps afterwards.
        var fd = (FileDesc)fileDesc0;
        lock (fd.Lock)
            fileInfo = InfoLocked(fd);
        return STATUS_SUCCESS;
    }

    public override int SetFileSize(
        object fileNode, object fileDesc0, ulong newSize, bool setAllocationSize,
        out FileInfo fileInfo)
    {
        fileInfo = default;
        if (!_writable)
            return STATUS_MEDIA_WRITE_PROTECTED;
        var fd = (FileDesc)fileDesc0;
        if (fd.Entry.IsDir)
            return STATUS_INVALID_DEVICE_REQUEST;
        try
        {
            lock (fd.Lock)
            {
                EnsureStageLocked(fd, pullExisting: true);
                if (!setAllocationSize)
                {
                    fd.Stage!.SetLength((long)newSize);
                    fd.Dirty = true;
                }
                else if ((long)newSize < fd.Stage!.Length)
                {
                    // Shrinking the allocation truncates the file.
                    fd.Stage.SetLength((long)newSize);
                    fd.Dirty = true;
                }
                fileInfo = InfoLocked(fd);
            }
            return STATUS_SUCCESS;
        }
        catch (Exception e) when (e is AdbException or IOException)
        {
            return STATUS_IO_DEVICE_ERROR;
        }
    }

    public override int CanDelete(object fileNode, object fileDesc0, string fileName)
    {
        if (!_writable)
            return STATUS_MEDIA_WRITE_PROTECTED;
        var fd = (FileDesc)fileDesc0;
        if (fd.Entry.IsDir)
        {
            // Match Windows semantics: only empty directories are deletable.
            var status = GetListing(fd.Entry.Path, out var entries);
            if (status != STATUS_SUCCESS)
                return status;
            if (entries!.Count != 0)
                return STATUS_DIRECTORY_NOT_EMPTY;
        }
        return STATUS_SUCCESS;
    }

    public override int Rename(
        object fileNode, object fileDesc0, string fileName, string newFileName,
        bool replaceIfExists)
    {
        if (!_writable)
            return STATUS_MEDIA_WRITE_PROTECTED;
        var fd = (FileDesc)fileDesc0;
        var srcDev = DevicePath(fileName);
        var dstDev = DevicePath(newFileName);
        if (srcDev == dstDev)
            return STATUS_SUCCESS;

        var status = LookupEntry(newFileName, out var target);
        if (status == STATUS_SUCCESS && target is not null)
        {
            if (!replaceIfExists)
                return STATUS_OBJECT_NAME_COLLISION;
            if (target.IsDir)
                return STATUS_ACCESS_DENIED; // Windows never replaces a directory
        }
        else if (status != STATUS_OBJECT_NAME_NOT_FOUND)
        {
            return status;
        }

        status = ShellOp($"mv {AdbClient.ShellQuote(srcDev)} {AdbClient.ShellQuote(dstDev)}");
        if (status != STATUS_SUCCESS)
            return status;
        InvalidateAfterMutation(srcDev);
        InvalidateAfterMutation(dstDev);
        lock (fd.Lock)
        {
            // Keep the open handle pointed at the new location so a pending
            // push-on-close lands on the renamed path.
            fd.Entry = new RemoteEntry
            {
                Name = newFileName[(newFileName.LastIndexOf('\\') + 1)..],
                Path = dstDev,
                IsDir = fd.Entry.IsDir,
                IsLink = fd.Entry.IsLink,
                Size = fd.Entry.Size,
                Modified = fd.Entry.Modified,
            };
        }
        return STATUS_SUCCESS;
    }

    // ----------------------------------------------------------- directories

    public override bool ReadDirectoryEntry(
        object fileNode, object fileDesc0, string pattern, string marker,
        ref object context, out string fileName, out FileInfo fileInfo)
    {
        var fd = (FileDesc)fileDesc0;
        fileName = null!;
        fileInfo = default;
        if (!fd.Entry.IsDir)
            return false;

        List<(string Name, FileInfo Info)> snapshot;
        lock (fd.Lock)
        {
            // Rebuild the snapshot at the start of each full enumeration so an
            // Explorer refresh on a kept-open handle sees fresh data.
            if (fd.DirSnapshot is null || (context is null && marker is null))
                fd.DirSnapshot = BuildDirSnapshot(fd.Entry);
            snapshot = fd.DirSnapshot;
        }

        var isRoot = fd.Entry.Path == _root;
        var dotCount = isRoot ? 0 : 2;
        int index;
        if (context is null)
        {
            index = marker switch
            {
                null => 0,
                "." => 1,
                ".." => dotCount,
                _ => FindAfterMarker(snapshot, marker, dotCount),
            };
        }
        else
        {
            index = (int)context;
        }

        if (index >= snapshot.Count)
            return false;
        context = index + 1;
        (fileName, fileInfo) = snapshot[index];
        return true;
    }

    private List<(string, FileInfo)> BuildDirSnapshot(RemoteEntry dir)
    {
        var snapshot = new List<(string, FileInfo)>();
        if (dir.Path != _root)
        {
            var self = MakeFileInfo(dir);
            snapshot.Add((".", self));
            snapshot.Add(("..", self)); // parent metadata approximated by self
        }
        if (GetListing(dir.Path, out var entries) == STATUS_SUCCESS)
        {
            // Ordinal sort so marker-based (restarted) enumeration can seek.
            foreach (var e in entries!.OrderBy(e => e.Name, StringComparer.Ordinal))
                snapshot.Add((e.Name, MakeFileInfo(e)));
        }
        return snapshot;
    }

    /// <summary>First index (past the dot entries) whose name sorts after marker.</summary>
    private static int FindAfterMarker(
        List<(string Name, FileInfo Info)> snapshot, string marker, int dotCount)
    {
        int lo = dotCount, hi = snapshot.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (string.CompareOrdinal(snapshot[mid].Name, marker) <= 0)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo;
    }

    // ------------------------------------------- remaining write rejections

    public override int SetVolumeLabel(string volumeLabel, out VolumeInfo volumeInfo)
    {
        volumeInfo = default;
        return STATUS_MEDIA_WRITE_PROTECTED; // label is fixed even in writable mode
    }

    public override int SetSecurity(
        object fileNode, object fileDesc, AccessControlSections sections,
        byte[] securityDescriptor)
        => STATUS_MEDIA_WRITE_PROTECTED; // no ACLs on Android storage

    public override int GetSecurity(object fileNode, object fileDesc, ref byte[] securityDescriptor)
    {
        securityDescriptor = _defaultSd;
        return STATUS_SUCCESS;
    }
}

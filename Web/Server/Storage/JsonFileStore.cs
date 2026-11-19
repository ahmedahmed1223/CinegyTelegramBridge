using System.Text.Json;

namespace CinegyBridge.Web.Storage;

/// <summary>
/// One JSON document on disk, written the way the bridge writes its state
/// files: a unique temporary file in the same folder, then an atomic replace,
/// so a crash mid-write leaves the previous copy rather than half of one.
/// </summary>
public sealed class JsonFileStore<T>(string path, Func<T> createEmpty) where T : class
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private T? _value;

    public async Task<TResult> ReadAsync<TResult>(Func<T, TResult> read)
    {
        await _gate.WaitAsync();
        try { return read(Load()); }
        finally { _gate.Release(); }
    }

    /// <summary>Applies a change and saves it. The change returns false to
    /// skip the write when it turned out to change nothing.</summary>
    public async Task<TResult> UpdateAsync<TResult>(Func<T, (bool Changed, TResult Result)> update)
    {
        await _gate.WaitAsync();
        try
        {
            var value = Load();
            var (changed, result) = update(value);
            if (changed) Save(value);
            return result;
        }
        finally { _gate.Release(); }
    }

    private T Load()
    {
        if (_value is not null) return _value;
        if (File.Exists(path))
        {
            using var stream = File.OpenRead(path);
            _value = JsonSerializer.Deserialize<T>(stream, JsonDefaults.Options);
        }
        return _value ??= createEmpty();
    }

    private void Save(T value)
    {
        var folder = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(folder);
        var temporary = Path.Combine(folder, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(value, JsonDefaults.Options));
        File.Move(temporary, path, overwrite: true);
    }
}

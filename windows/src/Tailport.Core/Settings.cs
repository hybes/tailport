using System.Text.Json;

namespace Tailport;

/// <summary>Remembered choices, stored as JSON in %APPDATA%\Tailport\settings.json.</summary>
public sealed class Settings
{
    public string? Machine { get; set; }
    public string? IgnoredPorts { get; set; }
    public string? IgnoredProcesses { get; set; }
    public Dictionary<string, List<NetworkDevice>> Devices { get; set; } = [];
    public bool? CheckForUpdates { get; set; }
    public DateTime? LastUpdateCheck { get; set; }
}

public sealed class SettingsStore(string path)
{
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public string Path { get; } = path;

    /// <summary>The user's settings file, or the file named by TAILPORT_SETTINGS (used for testing).</summary>
    public static SettingsStore Default() => new(Environment.GetEnvironmentVariable("TAILPORT_SETTINGS") is { Length: > 0 } custom
        ? custom
        : System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Tailport", "settings.json"));

    public Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(Path), Json) ?? new Settings(); }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return new Settings(); }
    }

    public void Save(Settings settings)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
        var temporary = Path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(settings, Json));
        File.Move(temporary, Path, overwrite: true);
    }
}

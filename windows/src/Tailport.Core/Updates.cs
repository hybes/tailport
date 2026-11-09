using System.IO.Compression;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Tailport;

/// <summary>Where updates come from.</summary>
public static class UpdateSource
{
    public const string Repository = "hybes/tailport";

    /// <summary>GitHub's latest release, or TAILPORT_UPDATE_FEED for testing.</summary>
    public static string Feed => Environment.GetEnvironmentVariable("TAILPORT_UPDATE_FEED") is { Length: > 0 } custom
        ? custom
        : $"https://api.github.com/repos/{Repository}/releases/latest";

    public static string ArchiveName(string version, Architecture architecture) =>
        $"tailport-{version}-windows-app-{(architecture == Architecture.Arm64 ? "arm64" : "x64")}.zip";

    /// <summary>The release version stamped into Tailport.exe by the build, or null for development builds.</summary>
    public static string? RunningVersion() => Assembly.GetEntryAssembly()?.GetCustomAttributes<AssemblyMetadataAttribute>()
        .FirstOrDefault(a => a.Key == "TailportVersion")?.Value is { Length: > 0 } version ? version : null;
}

public static class Versions
{
    /// <summary>The numbers of a dotted version such as v0.2.1; a pre-release suffix is ignored.</summary>
    public static int[]? Parse(string text)
    {
        var core = text.Trim().TrimStart('v').Split('-', '+')[0];
        var parts = core.Split('.');
        var numbers = new int[parts.Length];
        for (var i = 0; i < parts.Length; i++)
            if (!int.TryParse(parts[i], System.Globalization.NumberStyles.None, null, out numbers[i])) return null;
        return numbers;
    }

    public static string? Normalise(string text) => Parse(text) is { } parts ? string.Join('.', parts) : null;

    public static bool IsNewer(string candidate, string current)
    {
        if (Parse(candidate) is not { } a || Parse(current) is not { } b) return false;
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            var left = i < a.Length ? a[i] : 0;
            var right = i < b.Length ? b[i] : 0;
            if (left != right) return left > right;
        }
        return false;
    }
}

/// <summary>The parts of a GitHub release an update needs.</summary>
public sealed record AppRelease(string Version, string Page, string Archive, string Checksums, string ArchiveName)
{
    public static AppRelease Decode(string json, Func<string, string> archiveName)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            var version = Versions.Normalise(root.GetProperty("tag_name").GetString() ?? "") ?? throw new FormatException();
            var page = root.GetProperty("html_url").GetString() ?? throw new FormatException();
            var assets = root.GetProperty("assets").EnumerateArray()
                .ToDictionary(a => a.GetProperty("name").GetString() ?? "", a => a.GetProperty("browser_download_url").GetString() ?? "");
            var name = archiveName(version);
            if (!assets.TryGetValue(name, out var archive) || !assets.TryGetValue("SHA256SUMS", out var sums))
                throw new TailportException($"Tailport {version} has no download for this computer yet.");
            return new AppRelease(version, page, archive, sums, name);
        }
        catch (Exception error) when (error is JsonException or KeyNotFoundException or InvalidOperationException or FormatException or ArgumentException)
        {
            throw new TailportException("GitHub returned a release Tailport could not read.");
        }
    }

    /// <summary>The SHA-256 listed for <paramref name="name"/> in a SHA256SUMS file.</summary>
    public static string? Checksum(string name, string sums)
    {
        foreach (var line in sums.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var fields = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length == 2 && fields[1].TrimStart('*') == name) return fields[0].ToLowerInvariant();
        }
        return null;
    }
}

public enum UpdateKind { Idle, Checking, UpToDate, Available, Installing, Failed }

public sealed record UpdateState(UpdateKind Kind, AppRelease? Release = null, string? Message = null, bool Manual = false)
{
    public static readonly UpdateState Idle = new(UpdateKind.Idle);
}

/// <summary>
/// Checks GitHub for a newer Tailport.exe and swaps it in. Windows lets a running exe be renamed, so the old one
/// becomes Tailport.exe.old and is deleted on the next launch. Call it from the UI thread, like <see cref="AppModel"/>.
/// </summary>
public sealed class Updater
{
    public static readonly TimeSpan Interval = TimeSpan.FromDays(1);
    static readonly HttpClient Http = CreateClient();
    readonly AppModel model;
    readonly string exePath;
    readonly Func<string, Task<byte[]>> fetch;
    readonly Architecture architecture;
    CancellationTokenSource? schedule;

    public Updater(AppModel model, string? current, string exePath, Func<string, Task<byte[]>>? fetch = null,
                   Architecture? architecture = null)
    {
        this.model = model;
        Current = current;
        this.exePath = exePath;
        this.fetch = fetch ?? Download;
        this.architecture = architecture ?? RuntimeInformation.ProcessArchitecture;
    }

    /// <summary>Raised whenever <see cref="State"/> changes.</summary>
    public event Action? Changed;
    /// <summary>Raised once the new Tailport.exe is in place; the app should then quit and start it.</summary>
    public event Action? Installed;

    /// <summary>The running release, or null for development builds, which never update.</summary>
    public string? Current { get; }
    public bool Enabled => Current is not null;
    public UpdateState State { get; private set; } = UpdateState.Idle;
    public string ExePath => exePath;

    public bool Automatic
    {
        get => model.CheckForUpdates;
        set { model.CheckForUpdates = value; Changed?.Invoke(); }
    }

    public bool CheckDue => model.LastUpdateCheck is not { } last || DateTime.UtcNow - last >= Interval;

    void Set(UpdateState state) { State = state; Changed?.Invoke(); }

    /// <summary>Checks once a day while automatic checks are on. The first check waits a minute after launch.</summary>
    public void Start()
    {
        if (schedule is not null || !Enabled) return;
        schedule = new CancellationTokenSource();
        var token = schedule.Token;
        _ = Loop();
        async Task Loop()
        {
            try
            {
                await Task.Delay(TimeSpan.FromMinutes(1), token);
                while (!token.IsCancellationRequested)
                {
                    if (Automatic && CheckDue) await CheckAsync();
                    await Task.Delay(TimeSpan.FromHours(1), token);
                }
            }
            catch (OperationCanceledException) { }
        }
    }

    public void Stop() { schedule?.Cancel(); schedule = null; }

    /// <summary>Looks for a newer release. Automatic checks stay quiet unless one is found.</summary>
    public async Task CheckAsync(bool manual = false)
    {
        if (!Enabled || State.Kind is UpdateKind.Checking or UpdateKind.Installing) return;
        var previous = State;
        Set(new UpdateState(UpdateKind.Checking, Manual: manual));
        try
        {
            var json = Encoding.UTF8.GetString(await fetch(UpdateSource.Feed));
            var release = AppRelease.Decode(json, version => UpdateSource.ArchiveName(version, architecture));
            model.LastUpdateCheck = DateTime.UtcNow;
            Set(Versions.IsNewer(release.Version, Current!) ? new UpdateState(UpdateKind.Available, release)
                : manual ? new UpdateState(UpdateKind.UpToDate) : UpdateState.Idle);
        }
        catch (Exception error) when (error is TailportException or HttpRequestException or TaskCanceledException)
        {
            Set(manual ? new UpdateState(UpdateKind.Failed, Message: Describe(error, checking: true))
                : previous.Kind == UpdateKind.Available ? previous : UpdateState.Idle);
        }
    }

    /// <summary>Hides the update banner. A failed install goes back to offering the update.</summary>
    public void Dismiss()
    {
        if (State.Kind is UpdateKind.Checking or UpdateKind.Installing) return;
        Set(State is { Kind: UpdateKind.Failed, Release: { } release } ? new UpdateState(UpdateKind.Available, release) : UpdateState.Idle);
    }

    /// <summary>Downloads and checks <paramref name="release"/>, then puts it in place of the running Tailport.exe.</summary>
    public async Task InstallAsync(AppRelease release)
    {
        if (State.Kind == UpdateKind.Installing) return;
        Set(new UpdateState(UpdateKind.Installing, release));
        try
        {
            var sums = Encoding.UTF8.GetString(await fetch(release.Checksums));
            var expected = AppRelease.Checksum(release.ArchiveName, sums)
                ?? throw new TailportException($"The release’s SHA256SUMS doesn’t list {release.ArchiveName}.");
            var archive = await fetch(release.Archive);
            if (Convert.ToHexStringLower(SHA256.HashData(archive)) != expected)
                throw new TailportException("The download didn’t match its checksum, so it wasn’t installed.");
            Replace(exePath, archive);
        }
        catch (Exception error) when (error is TailportException or HttpRequestException or TaskCanceledException
                                          or IOException or UnauthorizedAccessException or InvalidDataException)
        {
            Set(new UpdateState(UpdateKind.Failed, release, Describe(error, checking: false)));
            return;
        }
        Installed?.Invoke();
    }

    /// <summary>Swaps Tailport.exe from <paramref name="archive"/> in for <paramref name="exe"/>, keeping the old one as .old.</summary>
    public static void Replace(string exe, byte[] archive)
    {
        using var zip = new ZipArchive(new MemoryStream(archive), ZipArchiveMode.Read);
        var entry = zip.Entries.FirstOrDefault(e => e.Name.Equals("Tailport.exe", StringComparison.OrdinalIgnoreCase))
            ?? throw new TailportException("The download doesn’t contain Tailport.exe.");
        var incoming = exe + ".new";
        var old = exe + ".old";
        try
        {
            entry.ExtractToFile(incoming, overwrite: true);
            if (File.Exists(old)) File.Delete(old);
            File.Move(exe, old);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            try { File.Delete(incoming); } catch (Exception) { }
            throw new TailportException($"Tailport can’t replace itself in {Path.GetDirectoryName(exe)}. Download the update from GitHub instead.");
        }
        try { File.Move(incoming, exe); }
        catch (Exception) { File.Move(old, exe); throw; }
    }

    /// <summary>Deletes the Tailport.exe.old left by the last update, once it is no longer running.</summary>
    public static void CleanUp(string exe)
    {
        try { File.Delete(exe + ".old"); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    static string Describe(Exception error, bool checking) => error switch
    {
        TailportException => error.Message,
        HttpRequestException { StatusCode: HttpStatusCode.NotFound } when checking => "No Tailport release is published yet.",
        HttpRequestException { StatusCode: HttpStatusCode.Forbidden or HttpStatusCode.TooManyRequests } => "GitHub is limiting requests. Try again in an hour.",
        HttpRequestException { StatusCode: { } status } => $"GitHub returned an error ({(int)status}). Try again later.",
        _ => checking ? "Couldn’t reach GitHub to check for updates. Check your connection and try again."
            : "The download didn’t finish. Check your connection and try again.",
    };

    static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(2) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Tailport");
        return client;
    }

    static async Task<byte[]> Download(string url)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (url.StartsWith("https://api.github.com/", StringComparison.Ordinal)) request.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var response = await Http.SendAsync(request);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsByteArrayAsync();
    }
}

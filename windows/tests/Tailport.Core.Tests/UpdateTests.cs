using System.IO.Compression;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Tailport.Tests;

public class UpdateTests : IDisposable
{
    readonly DirectoryInfo work = Directory.CreateTempSubdirectory("tailport-update-tests-");

    public void Dispose() => work.Delete(true);

    static byte[] Release(string tag, params string[] assets)
    {
        var version = tag.TrimStart('v');
        if (assets.Length == 0) assets = [$"tailport-{version}-windows-app-x64.zip", $"tailport-{version}-windows-app-arm64.zip", $"tailport-{version}-macos.zip", "SHA256SUMS"];
        var list = string.Join(",", assets.Select(a => $$"""{"name":"{{a}}","browser_download_url":"https://example.com/{{a}}"}"""));
        return Encoding.UTF8.GetBytes($$"""{"tag_name":"{{tag}}","html_url":"https://github.com/hybes/tailport/releases/tag/{{tag}}","assets":[{{list}}]}""");
    }

    static byte[] Zip(string folder, string content)
    {
        var stream = new MemoryStream();
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
        {
            using (var writer = new StreamWriter(zip.CreateEntry($"{folder}/Tailport.exe").Open())) writer.Write(content);
            using (var writer = new StreamWriter(zip.CreateEntry($"{folder}/README.md").Open())) writer.Write("readme");
        }
        return stream.ToArray();
    }

    AppModel Model() => new(new SettingsStore(Path.Combine(work.FullName, "settings.json")), () => "ssh", () => "tailscale");

    [Fact]
    public void VersionsCompareNumericallyAndIgnoreThePrefixAndSuffix()
    {
        Assert.True(Versions.IsNewer("0.10.0", "0.9.0"));
        Assert.True(Versions.IsNewer("v0.3", "0.2.1"));
        Assert.False(Versions.IsNewer("1.2.0", "1.2"));
        Assert.False(Versions.IsNewer("0.2.1", "0.3.0"));
        Assert.Equal("1.4.0", Versions.Normalise("v1.4.0-beta.1"));
        foreach (var bad in new[] { "", "v", "one", "1..2", "1.-2", "1.x" }) Assert.Null(Versions.Parse(bad));
    }

    [Fact]
    public void ReleasesPickTheArchiveForThisArchitecture()
    {
        var json = Encoding.UTF8.GetString(Release("v0.3.0"));
        var x64 = AppRelease.Decode(json, v => UpdateSource.ArchiveName(v, Architecture.X64));
        Assert.Equal("0.3.0", x64.Version);
        Assert.Equal("tailport-0.3.0-windows-app-x64.zip", x64.ArchiveName);
        Assert.Equal("https://example.com/tailport-0.3.0-windows-app-x64.zip", x64.Archive);
        Assert.Equal("https://example.com/SHA256SUMS", x64.Checksums);
        Assert.Equal("tailport-0.3.0-windows-app-arm64.zip", AppRelease.Decode(json, v => UpdateSource.ArchiveName(v, Architecture.Arm64)).ArchiveName);
        Assert.Throws<TailportException>(() => AppRelease.Decode(Encoding.UTF8.GetString(Release("v0.3.0", "SHA256SUMS")), v => UpdateSource.ArchiveName(v, Architecture.X64)));
        Assert.Throws<TailportException>(() => AppRelease.Decode("""{"message":"Not Found"}""", v => v));
        Assert.Throws<TailportException>(() => AppRelease.Decode("not json", v => v));
    }

    [Fact]
    public void ChecksumsAreReadFromShasumOutput()
    {
        const string sums = "aaa111  tailport-0.3.0-darwin.tar.gz\r\nBBB222 *tailport-0.3.0-windows-app-x64.zip\nccc333  tailport-0.3.0-windows-app-x64.zip.old\n";
        Assert.Equal("bbb222", AppRelease.Checksum("tailport-0.3.0-windows-app-x64.zip", sums));
        Assert.Null(AppRelease.Checksum("tailport-0.3.0-windows.zip", sums));
    }

    [Fact]
    public async Task ChecksOfferOnlyNewerReleasesAndManualChecksReportTheResult()
    {
        var model = Model();
        var served = Release("v0.3.0");
        var updater = new Updater(model, "0.2.1", Path.Combine(work.FullName, "Tailport.exe"), _ => Task.FromResult(served), Architecture.X64);
        Assert.True(updater.Automatic);
        Assert.True(updater.CheckDue);
        await updater.CheckAsync();
        Assert.Equal(UpdateKind.Available, updater.State.Kind);
        Assert.Equal("0.3.0", updater.State.Release?.Version);
        Assert.False(updater.CheckDue);

        served = Release("v0.2.1");
        await updater.CheckAsync();
        Assert.Equal(UpdateKind.Idle, updater.State.Kind);
        await updater.CheckAsync(manual: true);
        Assert.Equal(UpdateKind.UpToDate, updater.State.Kind);
        updater.Dismiss();
        Assert.Equal(UpdateKind.Idle, updater.State.Kind);

        served = Encoding.UTF8.GetBytes("not json");
        await updater.CheckAsync();
        Assert.Equal(UpdateKind.Idle, updater.State.Kind);
        await updater.CheckAsync(manual: true);
        Assert.Equal(UpdateKind.Failed, updater.State.Kind);

        var failing = new Updater(model, "0.2.1", "Tailport.exe", _ => throw new HttpRequestException("", null, HttpStatusCode.Forbidden));
        await failing.CheckAsync(manual: true);
        Assert.Equal("GitHub is limiting requests. Try again in an hour.", failing.State.Message);

        updater.Automatic = false;
        Assert.False(Model().CheckForUpdates);
        Assert.False(new Updater(model, null, "Tailport.exe").Enabled);
    }

    [Fact]
    public async Task InstallVerifiesTheChecksumThenSwapsTheExeAndKeepsTheOldOne()
    {
        var exe = Path.Combine(work.FullName, "Tailport.exe");
        File.WriteAllText(exe, "old");
        var archive = Zip("tailport-0.3.0-windows-app-x64", "new");
        var hash = Convert.ToHexStringLower(SHA256.HashData(archive));
        var sums = $"{hash}  tailport-0.3.0-windows-app-x64.zip\n";
        byte[] Serve(string url) => url.EndsWith("SHA256SUMS") ? Encoding.UTF8.GetBytes(sums) : url.EndsWith(".zip") ? archive : Release("v0.3.0");
        var updater = new Updater(Model(), "0.2.1", exe, url => Task.FromResult(Serve(url)), Architecture.X64);
        var installed = 0;
        updater.Installed += () => installed++;
        await updater.CheckAsync();
        var release = updater.State.Release!;

        sums = $"{new string('0', 64)}  tailport-0.3.0-windows-app-x64.zip\n";
        await updater.InstallAsync(release);
        Assert.Equal(UpdateKind.Failed, updater.State.Kind);
        Assert.Contains("checksum", updater.State.Message);
        Assert.Equal("old", File.ReadAllText(exe));
        Assert.Equal(0, installed);
        updater.Dismiss();
        Assert.Equal(UpdateKind.Available, updater.State.Kind);

        sums = $"{hash}  tailport-0.3.0-windows-app-x64.zip\n";
        await updater.InstallAsync(release);
        Assert.Equal(1, installed);
        Assert.Equal("new", File.ReadAllText(exe));
        Assert.Equal("old", File.ReadAllText(exe + ".old"));
        Assert.False(File.Exists(exe + ".new"));
        Updater.CleanUp(exe);
        Assert.False(File.Exists(exe + ".old"));
    }

    [Fact]
    public void ArchivesWithoutTheExeAreRejected()
    {
        var exe = Path.Combine(work.FullName, "Tailport.exe");
        File.WriteAllText(exe, "old");
        var stream = new MemoryStream();
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true)) zip.CreateEntry("README.md");
        Assert.Throws<TailportException>(() => Updater.Replace(exe, stream.ToArray()));
        Assert.Equal("old", File.ReadAllText(exe));
    }
}

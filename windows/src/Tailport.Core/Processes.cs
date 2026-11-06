using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Tailport;

public sealed record CommandResult(int Status, string Output, string Error);

public static class Tools
{
    /// <summary>The Tailscale CLI, which the Windows installer puts in Program Files.</summary>
    public static string Tailscale()
    {
        string[] candidates = OperatingSystem.IsWindows()
            ? [Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Tailscale", "tailscale.exe"),
               Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Tailscale", "tailscale.exe")]
            : ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/bin/tailscale"];
        return candidates.FirstOrDefault(File.Exists) ?? OnPath(OperatingSystem.IsWindows() ? "tailscale.exe" : "tailscale")
            ?? throw new TailportException("Install and open Tailscale on this computer, then refresh.");
    }

    /// <summary>The OpenSSH client that ships with Windows 10 and 11.</summary>
    public static string Ssh()
    {
        if (OperatingSystem.IsWindows())
        {
            var system = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh.exe");
            return File.Exists(system) ? system : OnPath("ssh.exe")
                ?? throw new TailportException("Install the OpenSSH Client from Settings › System › Optional features, then refresh.");
        }
        return File.Exists("/usr/bin/ssh") ? "/usr/bin/ssh" : OnPath("ssh") ?? throw new TailportException("Install an SSH client, then refresh.");
    }

    static string? OnPath(string name) =>
        (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Select(dir => Path.Combine(dir, name)).FirstOrDefault(File.Exists);
}

public static class Commands
{
    public static async Task<CommandResult> RunAsync(string path, IEnumerable<string> arguments, TimeSpan? timeout = null,
                                                     string? input = null, CancellationToken cancellation = default)
    {
        var info = new ProcessStartInfo(path)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = info };
        try { process.Start(); }
        catch (Win32Exception error) { throw new TailportException($"Could not start {Path.GetFileName(path)}: {error.Message}"); }
        ChildProcesses.Track(process);
        var output = process.StandardOutput.ReadToEndAsync(cancellation);
        var errors = process.StandardError.ReadToEndAsync(cancellation);
        // Unix line endings: input is a shell script for the remote machine.
        if (input is not null) await process.StandardInput.WriteAsync(input.Replace("\r\n", "\n").AsMemory(), cancellation);
        process.StandardInput.Close();
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        limit.CancelAfter(timeout ?? TimeSpan.FromSeconds(15));
        try { await process.WaitForExitAsync(limit.Token); }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            if (cancellation.IsCancellationRequested) throw;
            throw new TailportException("The connection timed out. Check Tailscale and that the other machine is awake, then refresh.");
        }
        return new CommandResult(process.ExitCode, await output, await errors);
    }
}

/// <summary>
/// One SSH connection that keeps a local forward open. The remote side prints a marker once SSH has
/// authenticated and the local listeners are bound, then waits on stdin so closing stdin ends it.
/// </summary>
public sealed class SshForward
{
    readonly Process process = new();
    readonly string target;
    readonly ListeningPort port;
    readonly Action<SshForward> onReady;
    readonly Action<SshForward, string?> onExit;
    readonly StringBuilder errors = new();
    readonly SynchronizationContext? context = SynchronizationContext.Current;
    readonly object gate = new();
    bool ready, stopped, finished;
    string? timeoutMessage;
    Timer? timeout;

    public SshForward(string target, ListeningPort port, string executable, Action<SshForward> onReady, Action<SshForward, string?> onExit)
    {
        this.target = target;
        this.port = port;
        this.onReady = onReady;
        this.onExit = onExit;
        var info = new ProcessStartInfo(executable)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in Ssh.ForwardingArguments(target, port)) info.ArgumentList.Add(argument);
        process.StartInfo = info;
        process.EnableRaisingEvents = true;
    }

    public Guid Id { get; } = Guid.NewGuid();
    public bool IsRunning { get { try { return !process.HasExited; } catch (InvalidOperationException) { return false; } } }

    public void Start()
    {
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data?.Contains("TAILPORT_READY") != true) return;
            lock (gate) { if (ready || stopped) return; ready = true; }
            timeout?.Dispose();
            Post(() => onReady(this));
        };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) lock (errors) errors.AppendLine(e.Data); };
        process.Exited += (_, _) => Post(Finish);
        try { process.Start(); }
        catch (Win32Exception error) { throw new TailportException($"Could not start SSH: {error.Message}"); }
        ChildProcesses.Track(process);
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        timeout = new Timer(_ =>
        {
            lock (gate) { if (ready || stopped) return; }
            timeoutMessage = "Forwarding did not become ready. Check SSH access and try again.";
            End();
        }, null, TimeSpan.FromSeconds(12), Timeout.InfiniteTimeSpan);
    }

    public void Stop()
    {
        lock (gate) stopped = true;
        timeout?.Dispose();
        End();
    }

    void End()
    {
        try { process.StandardInput.Close(); } catch (Exception) { }
        _ = Task.Delay(500).ContinueWith(_ => ForceStop());
    }

    public void ForceStop()
    {
        try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (Exception) { }
    }

    void Finish()
    {
        if (finished) return;
        finished = true;
        timeout?.Dispose();
        // Let the asynchronous stderr reader drain before reading what SSH reported.
        try { process.WaitForExit(); } catch (Exception) { }
        string message;
        lock (errors) message = errors.ToString();
        bool wasStopped;
        lock (gate) wasStopped = stopped;
        onExit(this, wasStopped ? null : timeoutMessage ?? Ssh.Explain(message, target, port.Number));
        process.Dispose();
    }

    void Post(Action action)
    {
        if (context is null) action();
        else context.Post(_ => action(), null);
    }
}

/// <summary>
/// Makes Windows end every SSH process Tailport started when Tailport exits, even if it crashes,
/// using a job object that kills its processes when the last handle closes. Elsewhere it is a no-op.
/// </summary>
public static class ChildProcesses
{
    static readonly Lazy<IntPtr> Job = new(CreateJob);

    public static void Track(Process process)
    {
        if (!OperatingSystem.IsWindows() || Job.Value == IntPtr.Zero) return;
        try { AssignProcessToJobObject(Job.Value, process.Handle); } catch (Exception) { }
    }

    static IntPtr CreateJob()
    {
        if (!OperatingSystem.IsWindows()) return IntPtr.Zero;
        var job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return IntPtr.Zero;
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        var size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
        var pointer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(info, pointer, false);
            SetInformationJobObject(job, 9 /* JobObjectExtendedLimitInformation */, pointer, (uint)size);
        }
        finally { Marshal.FreeHGlobal(pointer); }
        return job;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string? name);

    [DllImport("kernel32.dll")]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll")]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
}

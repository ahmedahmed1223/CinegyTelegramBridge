using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace BridgeManager;

internal sealed class ManagedRestartPipe(
    Func<uint, RestartWireRequest, CancellationToken, Task<RestartWireReply>> dispatch) : IDisposable
{
    private readonly CancellationTokenSource _stop = new();
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public string Name { get; } = "CinegyTelegramBridge.ManagedRestart." + Guid.NewGuid().ToString("N");

    public void Start() => _ = Task.Run(RunAsync);

    private async Task RunAsync()
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            var security = new PipeSecurity();
            security.AddAccessRule(new PipeAccessRule(identity.User ?? throw new IOException("Unknown pipe owner."),
                PipeAccessRights.ReadWrite, AccessControlType.Allow));
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid, null),
                PipeAccessRights.FullControl, AccessControlType.Deny));
            while (!_stop.IsCancellationRequested)
            {
                await using var pipe = NamedPipeServerStreamAcl.Create(Name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous, 4096, 4096, security);
                await pipe.WaitForConnectionAsync(_stop.Token);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
                timeout.CancelAfter(TimeSpan.FromMilliseconds(1200));
                try
                {
                    var request = await ReadAsync(pipe, timeout.Token);
                    var reply = request is not null && GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var pid)
                        ? await dispatch(pid, request, timeout.Token)
                        : new RestartWireReply(false, "restart_forbidden");
                    var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(reply, Json) + "\n");
                    await pipe.WriteAsync(bytes, timeout.Token);
                    await pipe.FlushAsync(timeout.Token);
                }
                catch (OperationCanceledException) { }
                catch (IOException) { }
                catch (JsonException) { }
            }
        }
        catch (OperationCanceledException) { }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static async Task<RestartWireRequest?> ReadAsync(Stream stream, CancellationToken token)
    {
        var buffer = new byte[4096];
        var size = 0;
        while (size < buffer.Length)
        {
            var count = await stream.ReadAsync(buffer.AsMemory(size), token);
            if (count == 0) return null;
            var end = Array.IndexOf(buffer, (byte)'\n', size, count);
            if (end >= 0) return JsonSerializer.Deserialize<RestartWireRequest>(buffer.AsSpan(0, end), Json);
            size += count;
        }

        return null;
    }

    public void Dispose() => _stop.Cancel();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint processId);
}

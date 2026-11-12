using System;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.ServiceProcess;
using System.Text;
using System.Threading;

namespace ITBS
{
    [DataContract]
    internal sealed class Health
    {
        [DataMember] public string State;
        [DataMember] public string AttemptUtc;
        [DataMember] public string LastSuccessUtc;
        [DataMember] public string Message;
        [DataMember] public int ChangedProcessors;
    }

    internal static class StateStore
    {
        private static readonly object Gate = new object();
        internal static string DataDirectory { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "ITBS"); } }
        internal static string StatusPath { get { return Path.Combine(DataDirectory, "status.json"); } }
        internal static void Write(Health status, bool log)
        {
            lock (Gate)
            {
                string temporary = StatusPath + ".tmp";
                using (FileStream stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
                    new DataContractJsonSerializer(typeof(Health)).WriteObject(stream, status);
                if (File.Exists(StatusPath)) File.Replace(temporary, StatusPath, null);
                else File.Move(temporary, StatusPath);
                if (!log) return;
                string path = Path.Combine(DataDirectory, "service.log");
                if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024)
                {
                    string old = path + ".1";
                    if (File.Exists(old)) File.Delete(old);
                    File.Move(path, old);
                }
                File.AppendAllText(path, status.AttemptUtc + " " + status.State + " " + status.Message.Replace('\r', ' ').Replace('\n', ' ') + Environment.NewLine, Encoding.UTF8);
            }
        }
        internal static Health Read()
        {
            using (FileStream stream = new FileStream(StatusPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                return (Health)new DataContractJsonSerializer(typeof(Health)).ReadObject(stream);
        }
    }

    internal sealed class ServiceHost : ServiceBase
    {
        private readonly CancellationTokenSource stopping = new CancellationTokenSource();
        private readonly AutoResetEvent wake = new AutoResetEvent(false);
        private Thread worker;
        private string lastState;
        private string lastMessage;
        private string lastSuccess;

        private ServiceConfig config = new ServiceConfig();

        // No polling: after a successful apply the service sleeps until the next resume
        // or stop. A failed or blocked attempt is retried with a growing delay only when
        // retrying is enabled in config.json; otherwise it fails directly and waits.
        internal static int RetryDelayMs(int consecutiveFailures, bool retry)
        {
            if (!retry || consecutiveFailures <= 0) return Timeout.Infinite;
            int[] minutes = { 1, 5, 15, 30 };
            return minutes[Math.Min(consecutiveFailures, minutes.Length) - 1] * 60000;
        }

        internal ServiceHost()
        {
            ServiceName = Setup.ServiceName;
            CanStop = true;
            CanShutdown = true;
            CanHandlePowerEvent = true;
            AutoLog = true;
        }

        protected override void OnStart(string[] args)
        {
            TurboEngine.CheckCpu();
            config = ServiceConfig.Load(Setup.ConfigPath);
            Setup.SecureDirectory(StateStore.DataDirectory);
            worker = new Thread(Work) { IsBackground = true, Name = "ITBS worker" };
            worker.Start();
        }

        private void Work()
        {
            string directory = Setup.EngineDirectory;
            WaitHandle[] events = { stopping.Token.WaitHandle, wake };
            int failures = 0;
            do
            {
                Health health = new Health { AttemptUtc = DateTime.UtcNow.ToString("o"), LastSuccessUtc = lastSuccess };
                try
                {
                    string[] competing = TurboEngine.CompetingApps();
                    if (competing.Length > 0)
                    {
                        health.State = "Waiting";
                        health.Message = "Close competing tuning tools: " + String.Join(", ", competing);
                    }
                    else
                    {
                        HardwareSession.Execute(directory, stopping.Token,
                            engine => health.ChangedProcessors = engine.Set(0));
                        health.State = "Enabled";
                        health.Message = "Turbo-disable bit 38 verified clear on all logical processors.";
                        lastSuccess = health.LastSuccessUtc = DateTime.UtcNow.ToString("o");
                    }
                }
                catch (OperationCanceledException) { return; }
                catch (Exception exception)
                {
                    health.State = "Error";
                    health.Message = exception.Message;
                }
                failures = health.State == "Enabled" ? 0 : failures + 1;
                if (failures > 0 && !config.Retry)
                    health.Message += " Automatic retry is off: fix the cause, then run Restart-Service ITBS.";
                try
                {
                    StateStore.Write(health, health.State != lastState || health.Message != lastMessage || health.ChangedProcessors > 0);
                    lastState = health.State;
                    lastMessage = health.Message;
                }
                catch (Exception exception)
                {
                    try { EventLog.WriteEntry("Could not record ITBS status: " + exception.Message, System.Diagnostics.EventLogEntryType.Error); }
                    catch { }
                    // A service with broken health reporting cannot be managed reliably.
                    Environment.Exit(1);
                }
            } while (WaitHandle.WaitAny(events, RetryDelayMs(failures, config.Retry)) != 0);
        }

        protected override bool OnPowerEvent(PowerBroadcastStatus status)
        {
            if (status == PowerBroadcastStatus.ResumeAutomatic || status == PowerBroadcastStatus.ResumeSuspend)
                wake.Set();
            return true;
        }

        protected override void OnCustomCommand(int command)
        {
            if (command == 128) wake.Set();
            else base.OnCustomCommand(command);
        }

        protected override void OnStop()
        {
            stopping.Cancel();
            wake.Set();
            if (worker != null && !worker.Join(30000)) throw new System.TimeoutException("ITBS worker did not stop in time.");
            StateStore.Write(new Health { State = "Stopped", AttemptUtc = DateTime.UtcNow.ToString("o"),
                LastSuccessUtc = lastSuccess, Message = "Service stopped; current CPU register values are retained." }, true);
        }
        protected override void OnShutdown() { OnStop(); }
    }
}

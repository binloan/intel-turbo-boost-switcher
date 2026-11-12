using System;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.ServiceProcess;
using System.Text;
using System.Threading;

namespace ITBS
{
    /// <summary>
    /// Service health as persisted to status.json and the service log.
    /// </summary>
    [DataContract]
    internal sealed class Health
    {
        /// <summary>
        /// Outcome of the last attempt: Enabled, Waiting, Error or Stopped.
        /// </summary>
        [DataMember]
        public string State;

        /// <summary>
        /// UTC time of the last attempt, in round-trip ("o") format.
        /// </summary>
        [DataMember]
        public string AttemptUtc;

        /// <summary>
        /// UTC time of the last successful attempt, in round-trip ("o") format.
        /// </summary>
        [DataMember]
        public string LastSuccessUtc;

        /// <summary>
        /// Human-readable detail for <see cref="State"/>.
        /// </summary>
        [DataMember]
        public string Message;

        /// <summary>
        /// Number of logical processors whose Turbo bit had to be changed by the last attempt.
        /// </summary>
        [DataMember]
        public int ChangedProcessors;
    }

    internal static class StateStore
    {
        private static readonly object s_gate = new object();

        /// <summary>
        /// The ITBS folder below the common application data directory.
        /// </summary>
        internal static string DataDirectory
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    "ITBS");
            }
        }

        /// <summary>
        /// Path of status.json in the data directory.
        /// </summary>
        internal static string StatusPath
        {
            get { return Path.Combine(DataDirectory, "status.json"); }
        }

        /// <summary>
        /// Replaces status.json with the given health and, when <paramref name="log"/> is set, appends a line
        /// to service.log. The log is rotated to service.log.1 once it exceeds 1 MiB.
        /// </summary>
        internal static void Write(Health status, bool log)
        {
            lock (s_gate)
            {
                string temporary = StatusPath + ".tmp";
                using (FileStream stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    new DataContractJsonSerializer(typeof(Health)).WriteObject(stream, status);
                }

                if (File.Exists(StatusPath))
                {
                    File.Replace(temporary, StatusPath, null);
                }
                else
                {
                    File.Move(temporary, StatusPath);
                }

                if (!log) return;
                string path = Path.Combine(DataDirectory, "service.log");
                if (File.Exists(path) && new FileInfo(path).Length > 1024 * 1024)
                {
                    string old = path + ".1";
                    if (File.Exists(old)) File.Delete(old);
                    File.Move(path, old);
                }

                File.AppendAllText(
                    path,
                    status.AttemptUtc + " " + status.State + " " + status.Message.Replace('\r', ' ').Replace('\n', ' ')
                        + Environment.NewLine,
                    Encoding.UTF8);
            }
        }

        /// <summary>
        /// Reads status.json. Other processes may keep the file open while it is being replaced.
        /// </summary>
        internal static Health Read()
        {
            using (FileStream stream = new FileStream(
                StatusPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                return (Health)new DataContractJsonSerializer(typeof(Health)).ReadObject(stream);
            }
        }
    }

    internal sealed class ServiceHost : ServiceBase
    {
        private readonly CancellationTokenSource _stopping = new CancellationTokenSource();
        private readonly AutoResetEvent _wake = new AutoResetEvent(false);
        private Thread _worker;
        private string _lastState;
        private string _lastMessage;
        private string _lastSuccess;

        private ServiceConfig _config = new ServiceConfig();

        internal ServiceHost()
        {
            ServiceName = Setup.ServiceName;
            CanStop = true;
            CanShutdown = true;
            CanHandlePowerEvent = true;
            AutoLog = true;
        }

        /// <summary>
        /// No polling: after a successful apply the service sleeps until the next resume
        /// or stop. A failed or blocked attempt is retried with a growing delay only when
        /// retrying is enabled in config.json; otherwise it fails directly and waits.
        /// </summary>
        internal static int RetryDelayMs(int consecutiveFailures, bool retry)
        {
            if (!retry || consecutiveFailures <= 0) return Timeout.Infinite;
            int[] minutes = { 1, 5, 15, 30 };
            return minutes[Math.Min(consecutiveFailures, minutes.Length) - 1] * 60000;
        }

        /// <summary>
        /// Checks the CPU, loads config.json, secures the data directory and starts the worker thread.
        /// </summary>
        protected override void OnStart(string[] args)
        {
            TurboEngine.CheckCpu();
            _config = ServiceConfig.Load(Setup.ConfigPath);
            Setup.SecureDirectory(StateStore.DataDirectory);
            _worker = new Thread(Work) { IsBackground = true, Name = "ITBS worker" };
            _worker.Start();
        }

        private void Work()
        {
            string directory = Setup.EngineDirectory;
            WaitHandle[] events = { _stopping.Token.WaitHandle, _wake };
            int failures = 0;
            do
            {
                Health health = new Health
                {
                    AttemptUtc = DateTime.UtcNow.ToString("o"),
                    LastSuccessUtc = _lastSuccess
                };
                try
                {
                    string[] competing = TurboEngine.CompetingApps();
                    if (competing.Length > 0)
                    {
                        health.State = "Waiting";
                        health.Message = "Close competing tuning tools: " + string.Join(", ", competing);
                    }
                    else
                    {
                        HardwareSession.Execute(
                            directory,
                            _stopping.Token,
                            engine => health.ChangedProcessors = engine.Set(0));
                        health.State = "Enabled";
                        health.Message = "Turbo-disable bit 38 verified clear on all logical processors.";
                        _lastSuccess = health.LastSuccessUtc = DateTime.UtcNow.ToString("o");
                    }
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception exception)
                {
                    health.State = "Error";
                    health.Message = exception.Message;
                }

                failures = health.State == "Enabled" ? 0 : failures + 1;
                if (failures > 0 && !_config.Retry)
                {
                    health.Message += " Automatic retry is off: fix the cause, then run Restart-Service ITBS.";
                }

                try
                {
                    StateStore.Write(
                        health,
                        health.State != _lastState
                            || health.Message != _lastMessage
                            || health.ChangedProcessors > 0);
                    _lastState = health.State;
                    _lastMessage = health.Message;
                }
                catch (Exception exception)
                {
                    try
                    {
                        EventLog.WriteEntry(
                            "Could not record ITBS status: " + exception.Message,
                            System.Diagnostics.EventLogEntryType.Error);
                    }
                    catch
                    {
                        // Best effort only: the process exits right below, so there is nobody left to report to.
                    }

                    // A service with broken health reporting cannot be managed reliably.
                    Environment.Exit(1);
                }
            }
            while (WaitHandle.WaitAny(events, RetryDelayMs(failures, _config.Retry)) != 0);
        }

        /// <summary>
        /// Wakes the worker after the machine resumes from sleep or hibernation.
        /// </summary>
        protected override bool OnPowerEvent(PowerBroadcastStatus status)
        {
            if (status == PowerBroadcastStatus.ResumeAutomatic || status == PowerBroadcastStatus.ResumeSuspend)
            {
                _wake.Set();
            }

            return true;
        }

        /// <summary>
        /// Command 128 wakes the worker so it applies the setting again immediately.
        /// </summary>
        protected override void OnCustomCommand(int command)
        {
            if (command == 128)
            {
                _wake.Set();
            }
            else
            {
                base.OnCustomCommand(command);
            }
        }

        /// <summary>
        /// Stops the worker (waiting up to 30 seconds) and records the Stopped state.
        /// </summary>
        protected override void OnStop()
        {
            _stopping.Cancel();
            _wake.Set();
            if (_worker != null && !_worker.Join(30000))
            {
                // Qualified because System.ServiceProcess also defines a TimeoutException.
                throw new System.TimeoutException("ITBS worker did not stop in time.");
            }

            StateStore.Write(
                new Health
                {
                    State = "Stopped",
                    AttemptUtc = DateTime.UtcNow.ToString("o"),
                    LastSuccessUtc = _lastSuccess,
                    Message = "Service stopped; current CPU register values are retained."
                },
                true);
        }

        /// <summary>
        /// Handles system shutdown like a stop.
        /// </summary>
        protected override void OnShutdown()
        {
            OnStop();
        }
    }
}

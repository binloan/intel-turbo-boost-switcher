using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace ITBS
{
    /// <summary>
    /// The IA32_MISC_ENABLE value read from one logical processor.
    /// </summary>
    internal sealed class CpuState
    {
        /// <summary>
        /// Logical processor number within processor group 0.
        /// </summary>
        public int Cpu;

        /// <summary>
        /// Raw 64-bit register value.
        /// </summary>
        public ulong Value;

        /// <summary>
        /// The Turbo-disable bit (bit 38) of <see cref="Value"/>: 1 means Turbo Boost is disabled.
        /// </summary>
        public int DisableBit
        {
            get { return (int)((Value >> 38) & 1); }
        }
    }

    internal sealed class TurboEngine
    {
        /// <summary>
        /// Bit mask of the Turbo-disable bit (bit 38).
        /// </summary>
        internal const ulong Mask = 1UL << 38;

        private readonly Func<string, string> _run;
        private readonly int _expectedProcessors;

        /// <summary>
        /// Creates an engine that talks to the hardware through <paramref name="runner"/>, which takes the
        /// msr-cmd arguments and returns its output. An <paramref name="expectedProcessors"/> of 0 means
        /// "accept any contiguous CPU list" (used by tests).
        /// </summary>
        public TurboEngine(Func<string, string> runner, int expectedProcessors = 0)
        {
            _run = runner;
            _expectedProcessors = expectedProcessors;
        }

        /// <summary>
        /// Hard safety gate: bit 38 of IA32_MISC_ENABLE is Intel-specific, and the
        /// msr-cmd calls here address processor group 0 only (at most 64 logical CPUs).
        /// Other Intel models are allowed but were never tested; the installer and
        /// manual tool warn about that. Returns the logical processor count.
        /// </summary>
        public static int CheckCpu()
        {
            using (RegistryKey key = Registry.LocalMachine.OpenSubKey(@"HARDWARE\DESCRIPTION\System\CentralProcessor"))
            {
                if (key == null) throw new InvalidOperationException("Could not read processor information.");
                int count = key.GetSubKeyNames().Length;
                using (RegistryKey cpu = key.OpenSubKey("0"))
                {
                    return ValidateCpu(
                        Convert.ToString(cpu == null ? null : cpu.GetValue("VendorIdentifier")),
                        count);
                }
            }
        }

        /// <summary>
        /// Throws unless the vendor is GenuineIntel and the logical processor count is 1-64.
        /// Returns <paramref name="count"/>.
        /// </summary>
        internal static int ValidateCpu(string vendor, int count)
        {
            if (vendor != "GenuineIntel")
            {
                throw new InvalidOperationException(
                    "This tool supports Intel processors only (found '" + vendor + "').");
            }

            if (count < 1 || count > 64)
            {
                throw new InvalidOperationException(
                    "Unsupported logical processor count (" + count
                    + "); only 1-64 processors in group 0 are supported.");
            }

            return count;
        }

        /// <summary>
        /// Lists running tuning tools that would fight over the same register, as "name (PID n)".
        /// </summary>
        public static string[] CompetingApps()
        {
            List<string> names = new List<string>();
            foreach (string name in new[] { "ThrottleStop", "QuickCPU", "XTU", "XTU3Service" })
            {
                foreach (Process process in Process.GetProcessesByName(name))
                {
                    using (process)
                    {
                        names.Add(name + " (PID " + process.Id + ")");
                    }
                }
            }

            return names.ToArray();
        }

        /// <summary>
        /// Parses the output of "msr-cmd -A -l read 0x1A0" into one row per CPU, ordered by CPU number.
        /// Throws <see cref="InvalidDataException"/> on unexpected lines or an incomplete CPU list.
        /// </summary>
        public static CpuState[] Parse(string output, int expectedProcessors = 0)
        {
            List<CpuState> rows = new List<CpuState>();
            foreach (string line in output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                if (string.IsNullOrWhiteSpace(line)
                    || Regex.IsMatch(line, @"^\s*GROUP\s+CPU\s+REG\s+VAL\s*$"))
                {
                    continue;
                }

                Match match = Regex.Match(
                    line,
                    @"^\s*0\s+(\d+)\s+0x000001a0\s+0x([0-9a-f]{16})\s*$",
                    RegexOptions.IgnoreCase);
                if (!match.Success) throw new InvalidDataException("Unexpected msr-cmd output: " + line);
                rows.Add(
                    new CpuState
                    {
                        Cpu = int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture),
                        Value = ulong.Parse(
                            match.Groups[2].Value,
                            NumberStyles.HexNumber,
                            CultureInfo.InvariantCulture)
                    });
            }

            if (rows.Count == 0
                || (expectedProcessors > 0 && rows.Count != expectedProcessors)
                || !rows.Select(x => x.Cpu).OrderBy(x => x).SequenceEqual(Enumerable.Range(0, rows.Count)))
            {
                throw new InvalidDataException(
                    "Expected exactly the contiguous CPUs 0-"
                    + ((expectedProcessors > 0 ? expectedProcessors : rows.Count) - 1)
                    + " in processor group 0; refusing incomplete results.");
            }

            return rows.OrderBy(x => x.Cpu).ToArray();
        }

        /// <summary>
        /// Reads IA32_MISC_ENABLE (0x1A0) from all logical processors.
        /// </summary>
        public CpuState[] Read()
        {
            return Parse(_run("-A -l read 0x1A0"), _expectedProcessors);
        }

        /// <summary>
        /// Sets the Turbo-disable bit to <paramref name="desiredBit"/> (0 or 1) on every processor that differs,
        /// then reads back and verifies the result. Returns the number of processors that were changed.
        /// </summary>
        public int Set(int desiredBit)
        {
            if (desiredBit != 0 && desiredBit != 1) throw new ArgumentOutOfRangeException("desiredBit");
            CpuState[] before = Read();
            int changed = 0;
            foreach (CpuState row in before)
            {
                if (row.DisableBit == desiredBit) continue;
                _run(
                    string.Format(
                        CultureInfo.InvariantCulture,
                        "-g 0 -p {0} setbit 0x1A0 38 {1}",
                        row.Cpu,
                        desiredBit));
                changed++;
            }

            CpuState[] after = Read();
            if (after.Length != before.Length)
            {
                throw new InvalidOperationException("The processor count changed during the operation.");
            }

            for (int i = 0; i < before.Length; i++)
            {
                if (after[i].DisableBit != desiredBit)
                {
                    throw new InvalidOperationException(
                        "CPU " + i + ": Turbo bit did not retain the requested value.");
                }

                if (((before[i].Value ^ after[i].Value) & ~Mask) != 0)
                {
                    throw new InvalidOperationException(
                        "CPU " + i + ": an unrelated register bit changed during verification.");
                }
            }

            return changed;
        }
    }

    internal static partial class Payload
    {
        /// <summary>
        /// Returns the SHA-256 of the file as upper-case hexadecimal without separators.
        /// </summary>
        public static string Hash(string path)
        {
            using (SHA256 sha = SHA256.Create())
            using (FileStream stream = File.OpenRead(path))
            {
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
            }
        }

        /// <summary>
        /// Throws <see cref="InvalidDataException"/> unless every pinned dependency in
        /// <paramref name="directory"/> matches its expected hash.
        /// </summary>
        public static void Verify(string directory)
        {
            foreach (KeyValuePair<string, string> pair in Hashes)
            {
                if (Hash(Path.Combine(directory, pair.Key)) != pair.Value)
                {
                    throw new InvalidDataException(
                        "Dependency hash mismatch: " + pair.Key + ". Rebuild from the pinned download.");
                }
            }
        }

        /// <summary>
        /// Runs msr-cmd.exe from <paramref name="directory"/> with the given arguments and returns its standard
        /// output. The call is killed after 20 seconds or when <paramref name="token"/> is cancelled.
        /// </summary>
        public static string Run(string directory, string arguments, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            ProcessStartInfo start = new ProcessStartInfo(Path.Combine(directory, "msr-cmd.exe"), arguments)
            {
                WorkingDirectory = directory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (Process process = Process.Start(start))
            {
                Task<string> stdout = process.StandardOutput.ReadToEndAsync();
                Task<string> stderr = process.StandardError.ReadToEndAsync();
                Stopwatch time = Stopwatch.StartNew();
                while (!process.WaitForExit(100))
                {
                    if (token.IsCancellationRequested || time.ElapsedMilliseconds > 20000)
                    {
                        try
                        {
                            process.Kill();
                        }
                        catch (InvalidOperationException)
                        {
                            // The process already exited, so there is nothing left to kill.
                        }

                        process.WaitForExit(5000);
                        token.ThrowIfCancellationRequested();
                        throw new TimeoutException(
                            "msr-cmd timed out. Some writes may have applied; read the state before retrying.");
                    }
                }

                if (!Task.WaitAll(new Task[] { stdout, stderr }, 5000))
                {
                    throw new TimeoutException("msr-cmd output did not close.");
                }

                if (process.ExitCode != 0)
                {
                    throw new InvalidOperationException(
                        "msr-cmd failed (" + process.ExitCode + "): " + stdout.Result.Trim() + " "
                        + stderr.Result.Trim()
                        + ". Check administrator rights and Windows Code Integrity/Defender logs."
                        + " Security settings were not changed.");
                }

                return stdout.Result;
            }
        }
    }

    internal static class HardwareSession
    {
        /// <summary>
        /// Runs <paramref name="action"/> with a <see cref="TurboEngine"/> while holding the machine-wide
        /// hardware mutex (waiting up to 10 seconds). It validates the CPU and the dependency hashes first.
        /// </summary>
        internal static void Execute(string directory, CancellationToken token, Action<TurboEngine> action)
        {
            MutexSecurity security = new MutexSecurity();
            WellKnownSidType[] fullControlSids =
            {
                WellKnownSidType.LocalSystemSid,
                WellKnownSidType.BuiltinAdministratorsSid
            };
            foreach (WellKnownSidType sid in fullControlSids)
            {
                security.AddAccessRule(
                    new MutexAccessRule(
                        new SecurityIdentifier(sid, null),
                        MutexRights.FullControl,
                        AccessControlType.Allow));
            }

            bool created;
            using (Mutex mutex = new Mutex(false, @"Global\ITBS.Hardware", out created, security))
            {
                bool held = false;
                try
                {
                    try
                    {
                        held = mutex.WaitOne(10000);
                    }
                    catch (AbandonedMutexException)
                    {
                        held = true;
                    }

                    if (!held) throw new TimeoutException("Another ITBS operation is still running.");
                    token.ThrowIfCancellationRequested();
                    int processors = TurboEngine.CheckCpu();
                    Payload.Verify(directory);
                    action(new TurboEngine(a => Payload.Run(directory, a, token), processors));
                }
                finally
                {
                    if (held) mutex.ReleaseMutex();
                }
            }
        }
    }
}

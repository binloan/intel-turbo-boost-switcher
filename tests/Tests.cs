using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using Microsoft.Win32;

namespace ITBS
{
    internal static class Tests
    {
        private static int passed;
        private static void Check(bool condition, string message)
        {
            if (!condition) throw new Exception(message);
            passed++;
        }
        private static void Throws(Action action, string expected)
        {
            try { action(); }
            catch (Exception exception) { Check(exception.Message.Contains(expected), "Unexpected failure: " + exception.Message); return; }
            throw new Exception("Expected failure: " + expected);
        }
        private sealed class Fake
        {
            internal ulong[] Values = Enumerable.Range(0, 12).Select(i => (0x851889UL + (ulong)i) | ((ulong)(i % 2) << 38)).ToArray();
            internal readonly List<string> Writes = new List<string>();
            internal bool Reject;
            internal bool Corrupt;
            internal int FailCpu = -1;
            internal string Output()
            {
                StringBuilder output = new StringBuilder("GROUP CPU REG VAL\n");
                for (int i = 0; i < 12; i++)
                {
                    ulong value = Values[i];
                    if (Corrupt && Writes.Count > 0 && i == 0) value ^= 1;
                    output.AppendFormat(CultureInfo.InvariantCulture, "0 {0} 0x000001a0 0x{1:x16}\n", i, value);
                }
                return output.ToString();
            }
            internal string Run(string arguments)
            {
                if (arguments == "-A -l read 0x1A0") return Output();
                string[] parts = arguments.Split(' ');
                Check(parts.Length == 8 && parts[0] == "-g" && parts[1] == "0" && parts[2] == "-p" &&
                    parts[4] == "setbit" && parts[5] == "0x1A0" && parts[6] == "38", "Unexpected hardware command: " + arguments);
                int cpu = Int32.Parse(parts[3]);
                int bit = Int32.Parse(parts[7]);
                Check(cpu >= 0 && cpu < 12 && (bit == 0 || bit == 1), "Invalid write target.");
                if (cpu == FailCpu) throw new IOException("simulated driver failure");
                Writes.Add(arguments);
                if (!Reject) Values[cpu] = (Values[cpu] & ~TurboEngine.Mask) | ((ulong)bit << 38);
                return "Readback ignored; a separate full-register read verifies the operation.";
            }
        }
        internal static int Main(string[] args)
        {
            try
            {
                Fake fake = new Fake();
                ulong[] original = (ulong[])fake.Values.Clone();
                TurboEngine engine = new TurboEngine(fake.Run, 12);
                Check(engine.Read()[0].DisableBit == 0 && engine.Read()[1].DisableBit == 1, "Incorrect bit polarity.");
                Check(engine.Set(0) == 6, "Enable should change only disabled CPUs.");
                Check(fake.Values.All(v => (v & TurboEngine.Mask) == 0), "Enable failed.");
                Check(original.Select(v => v & ~TurboEngine.Mask).SequenceEqual(fake.Values.Select(v => v & ~TurboEngine.Mask)), "Unrelated bits were modified.");
                int writes = fake.Writes.Count;
                Check(engine.Set(0) == 0 && fake.Writes.Count == writes, "Idempotent enable performed writes.");
                Check(engine.Set(1) == 12 && fake.Values.All(v => (v & TurboEngine.Mask) != 0), "Disable failed.");
                Throws(() => engine.Set(2), "desiredBit");
                Throws(() => TurboEngine.Parse(""), "Expected exactly");
                Throws(() => TurboEngine.Parse(fake.Output().Replace("0 11 ", "0 10 ")), "Expected exactly");
                Throws(() => TurboEngine.Parse(fake.Output().Replace("0 11 ", "1 11 ")), "Unexpected");
                Throws(() => TurboEngine.Parse(fake.Output() + "error"), "Unexpected");
                string eightCpus = String.Join("\n", Enumerable.Range(0, 8).Select(i => "0 " + i + " 0x000001a0 0x0000000000851889"));
                Check(TurboEngine.Parse(eightCpus).Length == 8, "Other processor counts should parse.");
                Check(TurboEngine.Parse(eightCpus, 8).Length == 8, "Matching expected processor count should parse.");
                Throws(() => TurboEngine.Parse(eightCpus, 12), "Expected exactly");
                Throws(() => TurboEngine.Parse(eightCpus.Replace("0 7 ", "0 9 ")), "Expected exactly");
                fake = new Fake { Reject = true };
                Throws(() => new TurboEngine(fake.Run).Set(0), "did not retain");
                fake = new Fake { Corrupt = true };
                Throws(() => new TurboEngine(fake.Run).Set(0), "unrelated register bit");
                fake = new Fake { FailCpu = 3 };
                Throws(() => new TurboEngine(fake.Run).Set(0), "simulated driver failure");
                Check(fake.Writes.Count == 1, "Writes continued after a driver failure.");
                // The service must not poll: idle after success, back off after failures.
                Check(ServiceHost.RetryDelayMs(0, true) == Timeout.Infinite && ServiceHost.RetryDelayMs(0, false) == Timeout.Infinite,
                    "A healthy service must wait for resume or stop without polling.");
                Check(ServiceHost.RetryDelayMs(1, true) == 60000 && ServiceHost.RetryDelayMs(2, true) == 300000 &&
                    ServiceHost.RetryDelayMs(3, true) == 900000 && ServiceHost.RetryDelayMs(4, true) == 1800000 && ServiceHost.RetryDelayMs(50, true) == 1800000,
                    "Retry delays should back off to 30 minutes.");
                Check(ServiceHost.RetryDelayMs(1, false) == Timeout.Infinite && ServiceHost.RetryDelayMs(50, false) == Timeout.Infinite,
                    "With retry off, a failure must not schedule another attempt.");
                Check(ServiceConfig.Parse("{}").Retry && ServiceConfig.Parse("{\"RetryOnFailure\": true}").Retry, "Retry should default to on.");
                Check(!ServiceConfig.Parse("{\"RetryOnFailure\": false}").Retry, "RetryOnFailure=false should turn retry off.");
                Check(ServiceConfig.Parse("{\"Unknown\": 1}").Retry, "Unknown settings should be ignored.");
                Throws(() => ServiceConfig.Parse("not json"), "Invalid config.json");
                Throws(() => ServiceConfig.Parse("{\"RetryOnFailure\": \"yes\"}"), "Invalid config.json");
                Check(ServiceConfig.Load(Path.Combine(Path.GetTempPath(), "itbs-missing-" + Guid.NewGuid().ToString("N") + ".json")).Retry, "A missing config file should mean defaults.");
                // CPU gate: pure rules, then the real registry read cross-checked against independent sources.
                Check(TurboEngine.ValidateCpu("GenuineIntel", 12) == 12 && TurboEngine.ValidateCpu("GenuineIntel", 64) == 64, "Intel CPUs should be allowed.");
                Throws(() => TurboEngine.ValidateCpu("AuthenticAMD", 16), "Intel processors only");
                Throws(() => TurboEngine.ValidateCpu(null, 4), "Intel processors only");
                Throws(() => TurboEngine.ValidateCpu("GenuineIntel", 0), "Unsupported logical processor count");
                Throws(() => TurboEngine.ValidateCpu("GenuineIntel", 65), "Unsupported logical processor count");
                string registryVendor;
                using (RegistryKey cpuKey = Registry.LocalMachine.OpenSubKey(@"HARDWARE\DESCRIPTION\System\CentralProcessor\0"))
                    registryVendor = Convert.ToString(cpuKey.GetValue("VendorIdentifier"));
                if (registryVendor == "GenuineIntel" && Environment.ProcessorCount <= 64)
                    Check(TurboEngine.CheckCpu() == Environment.ProcessorCount, "Registry processor count disagrees with the runtime.");
                else if (registryVendor != "GenuineIntel")
                    Throws(() => TurboEngine.CheckCpu(), "Intel processors only");
                CancellationTokenSource canceled = new CancellationTokenSource();
                canceled.Cancel();
                bool cancellationObserved = false;
                try { Payload.Run("not-used", "not-used", canceled.Token); }
                catch (OperationCanceledException) { cancellationObserved = true; }
                Check(cancellationObserved, "Canceled work attempted to launch a native process.");
                Check(args.Length == 1, "Pass the verified dependency directory to the tests.");
                Payload.Verify(args[0]);
                Check(true, "External dependency integrity verified.");
                Console.WriteLine("PASS: " + passed + " assertions; simulated driver and external dependency verification only. No hardware or service changes.");
                return 0;
            }
            catch (Exception exception) { Console.Error.WriteLine(exception); return 1; }
        }
    }
}

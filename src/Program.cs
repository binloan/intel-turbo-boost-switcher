using System;
using System.Reflection;
using System.ServiceProcess;

[assembly: AssemblyTitle("Intel TurboBoost Switcher locally compiled service")]
[assembly: AssemblyVersion("0.2.0.0")]

namespace ITBS
{
    internal static class Program
    {
        internal static int Main(string[] args)
        {
            if (args.Length != 1 || args[0] != "--service" || Environment.UserInteractive)
            {
                Console.Error.WriteLine("This locally compiled program is a Windows service. Use Install.ps1 or ITBS.ps1.");
                return 1;
            }
            ServiceBase.Run(new ServiceHost());
            return 0;
        }
    }
}

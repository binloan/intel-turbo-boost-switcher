using System;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;

namespace ITBS
{
    // Installation is handled by readable Install.ps1. This class owns only
    // the service's fixed runtime paths and data-directory permissions.
    internal static class Setup
    {
        internal const string ServiceName = "ITBS";
        internal static string ConfigPath { get { return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "config.json"); } }
        internal static string EngineDirectory { get { return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "engine"); } }
        internal static void SecureDirectory(string path)
        {
            if (Directory.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Refusing a redirected data directory: " + path);
            Directory.CreateDirectory(path);
            DirectorySecurity security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
            foreach (WellKnownSidType sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
                security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null), FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null), FileSystemRights.ReadAndExecute,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.SetAccessControl(path, security);
        }
    }
}

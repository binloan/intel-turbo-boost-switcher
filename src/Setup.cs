using System;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;

namespace ITBS
{
    /// <summary>
    /// Installation is handled by readable Install.ps1. This class owns only
    /// the service's fixed runtime paths and data-directory permissions.
    /// </summary>
    internal static class Setup
    {
        internal const string ServiceName = "ITBS";

        /// <summary>
        /// Path of the optional config.json next to the service executable.
        /// </summary>
        internal static string ConfigPath
        {
            get { return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "config.json"); }
        }

        /// <summary>
        /// Directory holding msr-cmd.exe and its driver files, below the service executable.
        /// </summary>
        internal static string EngineDirectory
        {
            get { return Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "engine"); }
        }

        /// <summary>
        /// Creates the data directory and restricts it to SYSTEM and Administrators (full control) plus
        /// read and execute for Users. Refuses a directory that is a reparse point.
        /// </summary>
        internal static void SecureDirectory(string path)
        {
            if (Directory.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            {
                throw new IOException("Refusing a redirected data directory: " + path);
            }

            Directory.CreateDirectory(path);
            DirectorySecurity security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));

            WellKnownSidType[] fullControlSids =
            {
                WellKnownSidType.LocalSystemSid,
                WellKnownSidType.BuiltinAdministratorsSid
            };
            foreach (WellKnownSidType sid in fullControlSids)
            {
                security.AddAccessRule(
                    new FileSystemAccessRule(
                        new SecurityIdentifier(sid, null),
                        FileSystemRights.FullControl,
                        InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                        PropagationFlags.None,
                        AccessControlType.Allow));
            }

            security.AddAccessRule(
                new FileSystemAccessRule(
                    new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                    FileSystemRights.ReadAndExecute,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                    PropagationFlags.None,
                    AccessControlType.Allow));
            Directory.SetAccessControl(path, security);
        }
    }
}

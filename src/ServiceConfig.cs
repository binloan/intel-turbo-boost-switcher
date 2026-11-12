using System;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;

namespace ITBS
{
    // Optional settings file (config.json) next to the service executable. It lives in the
    // protected install directory, so only Administrators and SYSTEM can change it; the
    // service reads it once at start. A missing file or missing setting means the defaults.
    [DataContract]
    internal sealed class ServiceConfig
    {
        [DataMember] public bool? RetryOnFailure { get; set; }

        // Default: retry a failed or blocked attempt with a growing delay.
        internal bool Retry { get { return RetryOnFailure ?? true; } }

        internal static ServiceConfig Parse(string json)
        {
            try
            {
                using (MemoryStream stream = new MemoryStream(Encoding.UTF8.GetBytes(json)))
                    return (ServiceConfig)new DataContractJsonSerializer(typeof(ServiceConfig)).ReadObject(stream) ?? new ServiceConfig();
            }
            catch (SerializationException exception)
            {
                throw new InvalidDataException("Invalid config.json: " + exception.Message, exception);
            }
        }

        internal static ServiceConfig Load(string path)
        {
            return File.Exists(path) ? Parse(File.ReadAllText(path, Encoding.UTF8)) : new ServiceConfig();
        }
    }
}

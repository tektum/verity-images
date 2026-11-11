using System;
using System.Globalization;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

// Exercises what the runtime image promises: execution, ICU, tzdata, OpenSSL and the root store.
if (args.Length > 0 && args[0] == "--exit")
{
    return int.Parse(args[1], CultureInfo.InvariantCulture);
}

Console.WriteLine("hello from verity dotnet");
Console.WriteLine("framework=" + System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription);
Console.WriteLine("version=" + Environment.Version);

var german = new CultureInfo("de-DE");
if ((1234.56).ToString("N2", german) != "1.234,56")
{
    Console.Error.WriteLine("icu: de-DE formatting is wrong (invariant globalization?)");
    return 10;
}
Console.WriteLine("icu=ok");

var berlin = TimeZoneInfo.FindSystemTimeZoneById("Europe/Berlin");
if (berlin.BaseUtcOffset != TimeSpan.FromHours(1))
{
    Console.Error.WriteLine("tzdata: unexpected Europe/Berlin offset");
    return 11;
}
Console.WriteLine("tzdata=ok");

var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("verity"))).ToLowerInvariant();
if (digest != "3cd3ea577d506c913ed42a399144c4bbff6189edccb3cd476ca981a457660b45")
{
    Console.Error.WriteLine("openssl: unexpected sha256 " + digest);
    return 13;
}
Console.WriteLine("openssl=ok");

using var store = new X509Store(StoreName.Root, StoreLocation.LocalMachine);
store.Open(OpenFlags.ReadOnly);
if (store.Certificates.Count == 0)
{
    Console.Error.WriteLine("trust: root store is empty");
    return 12;
}
Console.WriteLine("roots=ok");
return 0;

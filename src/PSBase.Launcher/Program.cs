using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.InteropServices;

namespace PSBase.Launcher;

internal static class Program
{
    private const string ProductDirectory = "PedroScripts/PSBase";
    private const string PayloadResource = "PSBase.Launcher.payload.zip";

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr window, string text, string caption, uint type);

    private static int Main(string[] args)
    {
        string version = GetVersion();
        string mutexName = $"Local\\PedroScripts.PSBase.{Sanitize(version)}";

        using var mutex = new Mutex(true, mutexName, out bool createdNew);
        if (!createdNew)
        {
            ShowMessage("PS Base is already running.", "PS Base", 0x40);
            return 0;
        }

        try
        {
            string installRoot = Path.Combine(GetApplicationRoot(), version);
            EnsurePayloadExtracted(installRoot, version);

            string runtimeRoot = Path.Combine(installRoot, "runtime");
            string pwshPath = Path.Combine(runtimeRoot, "pwsh.exe");
            string guiPath = Path.Combine(installRoot, "PS-Base-GUI.ps1");

            if (args.Length == 1 && args[0] == "--self-test")
            {
                return TestRuntime(pwshPath, installRoot);
            }

            var start = new ProcessStartInfo
            {
                FileName = pwshPath,
                WorkingDirectory = installRoot,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            start.Environment["PATH"] = runtimeRoot + Path.PathSeparator + Environment.GetEnvironmentVariable("PATH");
            start.ArgumentList.Add("-NoLogo");
            start.ArgumentList.Add("-NoProfile");
            start.ArgumentList.Add("-STA");
            start.ArgumentList.Add("-File");
            start.ArgumentList.Add(guiPath);

            using Process process = Process.Start(start)
                ?? throw new InvalidOperationException("The bundled PowerShell runtime could not be started.");

            process.WaitForExit();
            return process.ExitCode;
        }
        catch (Exception exception)
        {
            ShowMessage($"PS Base could not start.\n\n{exception.Message}", "PS Base startup error", 0x10);
            return 1;
        }
    }

    private static string GetVersion()
    {
        string version = Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "0.0.0";

        int metadataIndex = version.IndexOf('+');
        return metadataIndex >= 0 ? version[..metadataIndex] : version;
    }

    private static string Sanitize(string value)
    {
        return string.Concat(value.Select(character => char.IsLetterOrDigit(character) ? character : '_'));
    }

    private static string GetApplicationRoot()
    {
        string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new InvalidOperationException("A Windows user profile is required to run PS Base.");
        }

        return Path.Combine(localAppData, ProductDirectory);
    }

    private static void EnsurePayloadExtracted(string installRoot, string version)
    {
        string markerPath = Path.Combine(installRoot, ".psbase-version");
        string runtimePath = Path.Combine(installRoot, "runtime", "pwsh.exe");
        string guiPath = Path.Combine(installRoot, "PS-Base-GUI.ps1");

        if (File.Exists(markerPath) && File.Exists(runtimePath) && File.Exists(guiPath)
            && File.ReadAllText(markerPath).Trim() == version)
        {
            return;
        }

        string parent = Path.GetDirectoryName(installRoot)
            ?? throw new InvalidOperationException("The application directory is invalid.");
        Directory.CreateDirectory(parent);

        string temporaryRoot = Path.Combine(parent, ".extract-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporaryRoot);

        try
        {
            using Stream payload = Assembly.GetExecutingAssembly()
                .GetManifestResourceStream(PayloadResource)
                ?? throw new InvalidOperationException("The embedded PS Base application package is missing.");
            using var archive = new ZipArchive(payload, ZipArchiveMode.Read);

            string safeRoot = Path.GetFullPath(temporaryRoot) + Path.DirectorySeparatorChar;
            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                string relativePath = entry.FullName.Replace('/', Path.DirectorySeparatorChar);
                string destination = Path.GetFullPath(Path.Combine(temporaryRoot, relativePath));
                if (!destination.StartsWith(safeRoot, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException("The embedded application package contains an unsafe file path.");
                }

                if (entry.FullName.EndsWith("/", StringComparison.Ordinal))
                {
                    Directory.CreateDirectory(destination);
                    continue;
                }

                string? directory = Path.GetDirectoryName(destination);
                if (directory is not null)
                {
                    Directory.CreateDirectory(directory);
                }

                using Stream source = entry.Open();
                using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                source.CopyTo(output);
            }

            ValidateExtractedPayload(temporaryRoot);
            File.WriteAllText(Path.Combine(temporaryRoot, ".psbase-version"), version);

            if (Directory.Exists(installRoot))
            {
                Directory.Delete(installRoot, true);
            }

            Directory.Move(temporaryRoot, installRoot);
        }
        finally
        {
            if (Directory.Exists(temporaryRoot))
            {
                Directory.Delete(temporaryRoot, true);
            }
        }
    }

    private static void ValidateExtractedPayload(string root)
    {
        string[] requiredFiles =
        [
            "runtime/pwsh.exe",
            "PS-Base-GUI.ps1",
            "PS-Base.ps1",
            "catalog/resources.json",
            "src/PSBase/Catalog.psm1"
        ];

        foreach (string relativePath in requiredFiles)
        {
            if (!File.Exists(Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar))))
            {
                throw new InvalidDataException($"The embedded application package is incomplete: {relativePath}");
            }
        }
    }

    private static int TestRuntime(string pwshPath, string workingDirectory)
    {
        var start = new ProcessStartInfo
        {
            FileName = pwshPath,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        start.ArgumentList.Add("-NoLogo");
        start.ArgumentList.Add("-NoProfile");
        start.ArgumentList.Add("-Command");
        start.ArgumentList.Add("$PSVersionTable.PSVersion.ToString()");

        using Process process = Process.Start(start)
            ?? throw new InvalidOperationException("The bundled PowerShell runtime could not be started.");
        string output = process.StandardOutput.ReadToEnd();
        string error = process.StandardError.ReadToEnd();
        process.WaitForExit();

        if (process.ExitCode != 0 || !output.Trim().StartsWith("7.", StringComparison.Ordinal))
        {
            ShowMessage($"Bundled PowerShell runtime test failed.\n{output}\n{error}", "PS Base package test", 0x10);
            return 1;
        }

        ShowMessage($"Package extraction and PowerShell runtime test passed.\nPowerShell {output.Trim()}", "PS Base package test", 0x40);
        return 0;
    }

    private static void ShowMessage(string message, string title, uint type)
    {
        MessageBoxW(IntPtr.Zero, message, title, type | 0x1000);
    }
}
using System.Diagnostics;
using System.Text;

namespace SqlFormatterApp;

public sealed class FormatterService
{
    public string FormatterRoot { get; } = Path.Combine(AppContext.BaseDirectory, "Formatter");
    public string FormatterScriptPath => Path.Combine(FormatterRoot, "format-sql.ps1");
    public bool IsAvailable => File.Exists(FormatterScriptPath);

    public async Task<FormatterResult> FormatAsync(string input, CancellationToken cancellationToken = default)
    {
        if (!IsAvailable)
        {
            return FormatterResult.Failure($"Formatter script not found: {FormatterScriptPath}");
        }

        var escapedScriptPath = FormatterScriptPath.Replace("'", "''");
        var command =
            "[Console]::InputEncoding=[System.Text.UTF8Encoding]::new($false); " +
            "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false); " +
            $"& '{escapedScriptPath}'";

        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false)
        };

        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-Command");
        startInfo.ArgumentList.Add(command);

        using var process = new Process { StartInfo = startInfo };
        var stopwatch = Stopwatch.StartNew();

        if (!process.Start())
        {
            return FormatterResult.Failure("Windows PowerShell could not be started.");
        }

        var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);

        await process.StandardInput.WriteAsync(input.AsMemory(), cancellationToken);
        process.StandardInput.Close();

        await process.WaitForExitAsync(cancellationToken);
        var output = await outputTask;
        var error = await errorTask;
        stopwatch.Stop();

        if (process.ExitCode != 0)
        {
            var message = string.IsNullOrWhiteSpace(error)
                ? $"Formatter exited with code {process.ExitCode}."
                : error.Trim();
            return FormatterResult.Failure(message, stopwatch.ElapsedMilliseconds);
        }

        return FormatterResult.Successful(output.TrimEnd('\r', '\n'), stopwatch.ElapsedMilliseconds);
    }
}

public sealed record FormatterResult(bool Success, string Output, string? ErrorMessage, long ElapsedMilliseconds)
{
    public static FormatterResult Successful(string output, long elapsedMilliseconds) =>
        new(true, output, null, elapsedMilliseconds);

    public static FormatterResult Failure(string message, long elapsedMilliseconds = 0) =>
        new(false, string.Empty, message, elapsedMilliseconds);
}

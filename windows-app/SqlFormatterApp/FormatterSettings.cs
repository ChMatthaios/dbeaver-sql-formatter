using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace SqlFormatterApp;

public static class FormatterSettings
{
    private static readonly string FormatterRoot = Path.Combine(AppContext.BaseDirectory, "Formatter");
    private static readonly string SettingsDirectory = Path.Combine(FormatterRoot, "settings");
    private static readonly string SettingsPath = Path.Combine(SettingsDirectory, "settings.json");
    private static readonly string ExamplePath = Path.Combine(SettingsDirectory, "settings.example.json");

    public static int ReadMaxLineLength()
    {
        try
        {
            EnsureSettingsFile();
            var root = JsonNode.Parse(File.ReadAllText(SettingsPath)) as JsonObject;
            if (root?["maxLineLength"] is JsonValue value && value.TryGetValue<int>(out var width))
            {
                return Math.Clamp(width, 60, 400);
            }
        }
        catch
        {
            // The formatter itself also falls back to 120 if settings are invalid.
        }

        return 120;
    }

    public static void WriteMaxLineLength(int width)
    {
        width = Math.Clamp(width, 60, 400);
        Directory.CreateDirectory(SettingsDirectory);
        EnsureSettingsFile();

        JsonObject root;
        try
        {
            root = JsonNode.Parse(File.ReadAllText(SettingsPath)) as JsonObject ?? CreateDefaults();
        }
        catch
        {
            root = CreateDefaults();
        }

        root["maxLineLength"] = width;
        File.WriteAllText(
            SettingsPath,
            root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    private static void EnsureSettingsFile()
    {
        Directory.CreateDirectory(SettingsDirectory);
        if (File.Exists(SettingsPath))
        {
            return;
        }

        if (File.Exists(ExamplePath))
        {
            File.Copy(ExamplePath, SettingsPath, overwrite: false);
            return;
        }

        File.WriteAllText(
            SettingsPath,
            CreateDefaults().ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    private static JsonObject CreateDefaults() => new()
    {
        ["maxLineLength"] = 120,
        ["indentSize"] = 2,
        ["keywordCasing"] = "Uppercase",
        ["preserveCommentLineBoundaries"] = true
    };
}

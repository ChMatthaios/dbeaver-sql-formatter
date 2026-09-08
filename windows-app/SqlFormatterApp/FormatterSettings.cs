using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace SqlFormatterApp;

public sealed record FormatterPreferences(
    int MaxLineLength,
    int IndentSize,
    string KeywordCasing,
    bool PreserveCommentLineBoundaries)
{
    public static FormatterPreferences Defaults { get; } = new(
        MaxLineLength: 120,
        IndentSize: 2,
        KeywordCasing: "Uppercase",
        PreserveCommentLineBoundaries: true);
}

public static class FormatterSettings
{
    private static readonly string FormatterRoot = Path.Combine(AppContext.BaseDirectory, "Formatter");
    private static readonly string SettingsDirectory = Path.Combine(FormatterRoot, "settings");
    private static readonly string SettingsPath = Path.Combine(SettingsDirectory, "settings.json");
    private static readonly string ExamplePath = Path.Combine(SettingsDirectory, "settings.example.json");

    public static FormatterPreferences Read()
    {
        var defaults = FormatterPreferences.Defaults;

        try
        {
            EnsureSettingsFile();
            var root = JsonNode.Parse(File.ReadAllText(SettingsPath)) as JsonObject;
            if (root is null)
            {
                return defaults;
            }

            var width = ReadInt(root, "maxLineLength", defaults.MaxLineLength);
            width = Math.Clamp(width, 60, 400);

            var indent = ReadInt(root, "indentSize", defaults.IndentSize);
            if (indent is not 2 and not 4)
            {
                indent = defaults.IndentSize;
            }

            var casing = ReadString(root, "keywordCasing", defaults.KeywordCasing);
            casing = NormalizeKeywordCasing(casing);

            var preserveComments = ReadBool(
                root,
                "preserveCommentLineBoundaries",
                defaults.PreserveCommentLineBoundaries);

            return new FormatterPreferences(width, indent, casing, preserveComments);
        }
        catch
        {
            // The PowerShell formatter has its own safe defaults as well.
            return defaults;
        }
    }

    public static void Write(FormatterPreferences preferences)
    {
        var normalized = new FormatterPreferences(
            MaxLineLength: Math.Clamp(preferences.MaxLineLength, 60, 400),
            IndentSize: preferences.IndentSize == 4 ? 4 : 2,
            KeywordCasing: NormalizeKeywordCasing(preferences.KeywordCasing),
            PreserveCommentLineBoundaries: preferences.PreserveCommentLineBoundaries);

        Directory.CreateDirectory(SettingsDirectory);

        var root = new JsonObject
        {
            ["maxLineLength"] = normalized.MaxLineLength,
            ["indentSize"] = normalized.IndentSize,
            ["keywordCasing"] = normalized.KeywordCasing,
            ["preserveCommentLineBoundaries"] = normalized.PreserveCommentLineBoundaries
        };

        File.WriteAllText(
            SettingsPath,
            root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    public static void ResetToDefaults() => Write(FormatterPreferences.Defaults);

    public static int ReadMaxLineLength() => Read().MaxLineLength;

    public static void WriteMaxLineLength(int width)
    {
        var current = Read();
        Write(current with { MaxLineLength = Math.Clamp(width, 60, 400) });
    }

    private static int ReadInt(JsonObject root, string name, int fallback)
    {
        return root[name] is JsonValue value && value.TryGetValue<int>(out var result)
            ? result
            : fallback;
    }

    private static string ReadString(JsonObject root, string name, string fallback)
    {
        return root[name] is JsonValue value && value.TryGetValue<string>(out var result) && !string.IsNullOrWhiteSpace(result)
            ? result
            : fallback;
    }

    private static bool ReadBool(JsonObject root, string name, bool fallback)
    {
        return root[name] is JsonValue value && value.TryGetValue<bool>(out var result)
            ? result
            : fallback;
    }

    private static string NormalizeKeywordCasing(string? value)
    {
        if (string.Equals(value, "Lowercase", StringComparison.OrdinalIgnoreCase))
        {
            return "Lowercase";
        }

        if (string.Equals(value, "Preserve", StringComparison.OrdinalIgnoreCase))
        {
            return "Preserve";
        }

        return "Uppercase";
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

        Write(FormatterPreferences.Defaults);
    }
}

using System.IO;
using System.Text.Json;

namespace SqlFormatterApp;

public sealed class FormatterPreferences
{
    public int MaxLineLength { get; set; } = 120;
    public int IndentSize { get; set; } = 2;
    public string KeywordCasing { get; set; } = "Uppercase";
    public bool PreserveCommentLineBoundaries { get; set; } = true;
    public AdvancedBeautifierPreferences Advanced { get; set; } = new();
}

public sealed class AdvancedBeautifierPreferences
{
    public bool Enabled { get; set; } = true;
    public ParenthesisPreferences Parentheses { get; set; } = new();
    public ListPreferences Lists { get; set; } = new();
    public ClausePreferences Clauses { get; set; } = new();
    public CasePreferences Case { get; set; } = new();
    public SpacingPreferences Spacing { get; set; } = new();
}

public sealed class ParenthesisPreferences
{
    public string FunctionSpaceBeforeParen { get; set; } = "Preserve";
    public string InsideParentheses { get; set; } = "Preserve";
    public string SubqueryOpening { get; set; } = "Preserve";
    public string SubqueryClosing { get; set; } = "Preserve";
    public string CteAsParenthesis { get; set; } = "Preserve";
}

public sealed class ListPreferences
{
    public string Select { get; set; } = "Preserve";
    public string GroupBy { get; set; } = "Preserve";
    public string OrderBy { get; set; } = "Preserve";
    public string UpdateSet { get; set; } = "Preserve";
    public string InsertColumns { get; set; } = "Preserve";
    public string Values { get; set; } = "Preserve";
    public string InList { get; set; } = "Preserve";
    public string FunctionArguments { get; set; } = "Preserve";
    public string CommaStyle { get; set; } = "Preserve";
    public string ContinuationIndent { get; set; } = "Preserve";
}

public sealed class ClausePreferences
{
    public string Alignment { get; set; } = "Preserve";
    public string BooleanOperatorPosition { get; set; } = "Preserve";
    public string JoinLayout { get; set; } = "Preserve";
    public string OnClause { get; set; } = "Preserve";
    public string CteLayout { get; set; } = "Preserve";
    public bool BlankLineBetweenCtes { get; set; }
}

public sealed class CasePreferences
{
    public string Style { get; set; } = "Preserve";
    public string ThenResult { get; set; } = "Preserve";
    public string ElseResult { get; set; } = "Preserve";
}

public sealed class SpacingPreferences
{
    public string ComparisonOperators { get; set; } = "Preserve";
    public string AfterComma { get; set; } = "Preserve";
}

public static class FormatterSettings
{
    private static readonly string FormatterRoot = Path.Combine(AppContext.BaseDirectory, "Formatter");
    private static readonly string SettingsDirectory = Path.Combine(FormatterRoot, "settings");
    private static readonly string SettingsPath = Path.Combine(SettingsDirectory, "settings.json");
    private static readonly string ExamplePath = Path.Combine(SettingsDirectory, "settings.example.json");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    public static FormatterPreferences Read()
    {
        try
        {
            EnsureSettingsFile();
            var settings = JsonSerializer.Deserialize<FormatterPreferences>(File.ReadAllText(SettingsPath), JsonOptions)
                           ?? CreateDefaults();
            Normalize(settings);
            return settings;
        }
        catch
        {
            return CreateDefaults();
        }
    }

    public static int ReadMaxLineLength() => Read().MaxLineLength;

    public static void Write(FormatterPreferences preferences)
    {
        Normalize(preferences);
        Directory.CreateDirectory(SettingsDirectory);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(preferences, JsonOptions));
    }

    public static void WriteMaxLineLength(int width)
    {
        var settings = Read();
        settings.MaxLineLength = width;
        Write(settings);
    }

    public static FormatterPreferences ResetToDefaults()
    {
        var defaults = CreateDefaults();
        Write(defaults);
        return defaults;
    }

    public static FormatterPreferences CreateDefaults() => new();

    private static void Normalize(FormatterPreferences settings)
    {
        settings.MaxLineLength = Math.Clamp(settings.MaxLineLength, 60, 400);
        settings.IndentSize = settings.IndentSize == 4 ? 4 : 2;
        settings.KeywordCasing = Allowed(settings.KeywordCasing, "Uppercase", "Lowercase", "Preserve");
        settings.Advanced ??= new AdvancedBeautifierPreferences();
        settings.Advanced.Parentheses ??= new ParenthesisPreferences();
        settings.Advanced.Lists ??= new ListPreferences();
        settings.Advanced.Clauses ??= new ClausePreferences();
        settings.Advanced.Case ??= new CasePreferences();
        settings.Advanced.Spacing ??= new SpacingPreferences();

        var p = settings.Advanced.Parentheses;
        p.FunctionSpaceBeforeParen = Allowed(p.FunctionSpaceBeforeParen, "Preserve", "NoSpace", "Space");
        p.InsideParentheses = Allowed(p.InsideParentheses, "Preserve", "NoSpace", "Space");
        p.SubqueryOpening = Allowed(p.SubqueryOpening, "Preserve", "SameLine", "NewLine");
        p.SubqueryClosing = Allowed(p.SubqueryClosing, "Preserve", "SameLine", "NewLine");
        p.CteAsParenthesis = Allowed(p.CteAsParenthesis, "Preserve", "SameLine", "NewLine");

        var l = settings.Advanced.Lists;
        l.Select = ListStyle(l.Select);
        l.GroupBy = ListStyle(l.GroupBy);
        l.OrderBy = ListStyle(l.OrderBy);
        l.UpdateSet = ListStyle(l.UpdateSet);
        l.InsertColumns = ListStyle(l.InsertColumns);
        l.Values = ListStyle(l.Values);
        l.InList = ListStyle(l.InList);
        l.FunctionArguments = ListStyle(l.FunctionArguments);
        l.CommaStyle = Allowed(l.CommaStyle, "Preserve", "Trailing", "Leading");
        l.ContinuationIndent = Allowed(l.ContinuationIndent, "Preserve", "Align", "Indent");

        var c = settings.Advanced.Clauses;
        c.Alignment = Allowed(c.Alignment, "Preserve", "IBM", "Left", "Indented");
        c.BooleanOperatorPosition = Allowed(c.BooleanOperatorPosition, "Preserve", "Leading", "Trailing");
        c.JoinLayout = Allowed(c.JoinLayout, "Preserve", "EachNewLine", "CompactWhenPossible");
        c.OnClause = Allowed(c.OnClause, "Preserve", "SameLine", "NewLine");
        c.CteLayout = Allowed(c.CteLayout, "Preserve", "CompactHeader", "ExpandedHeader");

        var k = settings.Advanced.Case;
        k.Style = Allowed(k.Style, "Preserve", "Multiline", "CompactShort");
        k.ThenResult = Allowed(k.ThenResult, "Preserve", "SameLine", "NewLine");
        k.ElseResult = Allowed(k.ElseResult, "Preserve", "SameLine", "NewLine");

        var s = settings.Advanced.Spacing;
        s.ComparisonOperators = Allowed(s.ComparisonOperators, "Preserve", "Spaced", "Tight");
        s.AfterComma = Allowed(s.AfterComma, "Preserve", "Space", "NoSpace");
    }

    private static string ListStyle(string? value) =>
        Allowed(value, "Preserve", "Compact", "Wrap", "OnePerLine");

    private static string Allowed(string? value, params string[] allowed)
    {
        foreach (var item in allowed)
        {
            if (string.Equals(value, item, StringComparison.OrdinalIgnoreCase))
            {
                return item;
            }
        }
        return allowed[0];
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

        Write(CreateDefaults());
    }
}

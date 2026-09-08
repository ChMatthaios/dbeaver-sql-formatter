using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace SqlFormatterApp;

public enum UiTheme
{
    Light,
    Dark
}

public static class ThemeService
{
    private static readonly string SettingsDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SqlFormatterApp");

    private static readonly string SettingsPath = Path.Combine(SettingsDirectory, "ui-settings.json");

    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int DwmwaUseImmersiveDarkModeLegacy = 19;

    public static UiTheme Current { get; private set; } = UiTheme.Dark;

    public static void ApplySavedTheme()
    {
        Apply(ReadSavedTheme(), persist: false);
    }

    public static void Toggle()
    {
        Apply(Current == UiTheme.Dark ? UiTheme.Light : UiTheme.Dark);
    }

    public static void Apply(UiTheme theme, bool persist = true)
    {
        Current = theme;
        var palette = theme == UiTheme.Dark ? DarkPalette : LightPalette;

        foreach (var pair in palette)
        {
            Application.Current.Resources[pair.Key] = Brush(pair.Value);
        }

        // WPF's native ComboBox/ScrollBar templates still reference SystemColors.
        // Override those resources as well so selected items never become
        // white-on-white or dark-on-dark when Windows changes its own theme.
        SetSystemBrush(SystemColors.WindowBrushKey, palette["ControlBrush"]);
        SetSystemBrush(SystemColors.ControlBrushKey, palette["ControlBrush"]);
        SetSystemBrush(SystemColors.ControlLightBrushKey, palette["SurfaceAltBrush"]);
        SetSystemBrush(SystemColors.ControlLightLightBrushKey, palette["SurfaceBrush"]);
        SetSystemBrush(SystemColors.ControlDarkBrushKey, palette["BorderBrush"]);
        SetSystemBrush(SystemColors.ControlDarkDarkBrushKey, palette["BorderBrush"]);
        SetSystemBrush(SystemColors.ControlTextBrushKey, palette["TextPrimaryBrush"]);
        SetSystemBrush(SystemColors.WindowTextBrushKey, palette["TextPrimaryBrush"]);
        SetSystemBrush(SystemColors.MenuBrushKey, palette["SurfaceBrush"]);
        SetSystemBrush(SystemColors.MenuTextBrushKey, palette["TextPrimaryBrush"]);
        SetSystemBrush(SystemColors.HighlightBrushKey, palette["SelectionBrush"]);
        SetSystemBrush(SystemColors.HighlightTextBrushKey, palette["TextPrimaryBrush"]);
        SetSystemBrush(SystemColors.GrayTextBrushKey, palette["DisabledTextBrush"]);
        SetSystemBrush(SystemColors.ActiveBorderBrushKey, palette["BorderBrush"]);
        SetSystemBrush(SystemColors.InactiveBorderBrushKey, palette["BorderBrush"]);

        if (persist)
        {
            SaveTheme(theme);
        }

        foreach (Window window in Application.Current.Windows)
        {
            ApplyWindowChrome(window);
        }
    }

    public static void ApplyWindowChrome(Window window)
    {
        try
        {
            var handle = new WindowInteropHelper(window).Handle;
            if (handle == IntPtr.Zero)
            {
                return;
            }

            var enabled = Current == UiTheme.Dark ? 1 : 0;
            if (DwmSetWindowAttribute(handle, DwmwaUseImmersiveDarkMode, ref enabled, sizeof(int)) != 0)
            {
                DwmSetWindowAttribute(handle, DwmwaUseImmersiveDarkModeLegacy, ref enabled, sizeof(int));
            }
        }
        catch
        {
            // The application theme remains valid even if the Windows title bar
            // API is unavailable on an older Windows build.
        }
    }

    private static UiTheme ReadSavedTheme()
    {
        try
        {
            if (!File.Exists(SettingsPath))
            {
                return UiTheme.Dark;
            }

            using var doc = JsonDocument.Parse(File.ReadAllText(SettingsPath));
            if (doc.RootElement.TryGetProperty("theme", out var value) &&
                Enum.TryParse<UiTheme>(value.GetString(), ignoreCase: true, out var theme))
            {
                return theme;
            }
        }
        catch
        {
            // Fall through to the calm dark default.
        }

        return UiTheme.Dark;
    }

    private static void SaveTheme(UiTheme theme)
    {
        try
        {
            Directory.CreateDirectory(SettingsDirectory);
            File.WriteAllText(
                SettingsPath,
                JsonSerializer.Serialize(new { theme = theme.ToString() }, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch
        {
            // Theme persistence should never stop the formatter from working.
        }
    }

    private static void SetSystemBrush(object key, string color)
    {
        Application.Current.Resources[key] = Brush(color);
    }

    private static SolidColorBrush Brush(string color)
    {
        var converted = (Color)ColorConverter.ConvertFromString(color)!;
        var brush = new SolidColorBrush(converted);
        brush.Freeze();
        return brush;
    }

    private static readonly IReadOnlyDictionary<string, string> DarkPalette =
        new Dictionary<string, string>
        {
            ["WindowBackgroundBrush"] = "#20252D",
            ["TopBarBrush"] = "#252B34",
            ["SurfaceBrush"] = "#2A303A",
            ["SurfaceAltBrush"] = "#303743",
            ["EditorBrush"] = "#272D36",
            ["EditorOutputBrush"] = "#252B33",
            ["BorderBrush"] = "#46505D",
            ["TextPrimaryBrush"] = "#E6E9EF",
            ["TextSecondaryBrush"] = "#C7CED8",
            ["TextMutedBrush"] = "#9AA5B3",
            ["ControlBrush"] = "#343C48",
            ["ControlHoverBrush"] = "#3C4654",
            ["AccentBrush"] = "#5B7DBA",
            ["AccentHoverBrush"] = "#6A8AC6",
            ["AccentTextBrush"] = "#F8FAFC",
            ["SelectionBrush"] = "#4C627E",
            ["DisabledTextBrush"] = "#7F8996"
        };

    private static readonly IReadOnlyDictionary<string, string> LightPalette =
        new Dictionary<string, string>
        {
            ["WindowBackgroundBrush"] = "#E1E6EB",
            ["TopBarBrush"] = "#E8EDF2",
            ["SurfaceBrush"] = "#EDF1F4",
            ["SurfaceAltBrush"] = "#E6EBF0",
            ["EditorBrush"] = "#F2F4F6",
            ["EditorOutputBrush"] = "#ECEFF2",
            ["BorderBrush"] = "#B7C1CB",
            ["TextPrimaryBrush"] = "#26323E",
            ["TextSecondaryBrush"] = "#465567",
            ["TextMutedBrush"] = "#68798B",
            ["ControlBrush"] = "#DDE3E9",
            ["ControlHoverBrush"] = "#D2DAE2",
            ["AccentBrush"] = "#5876A7",
            ["AccentHoverBrush"] = "#496793",
            ["AccentTextBrush"] = "#F8FAFC",
            ["SelectionBrush"] = "#C1D0E2",
            ["DisabledTextBrush"] = "#8995A2"
        };

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        IntPtr hwnd,
        int attribute,
        ref int attributeValue,
        int attributeSize);
}

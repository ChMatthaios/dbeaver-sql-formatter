using System.Collections;
using System.Windows;
using System.Windows.Controls;

namespace SqlFormatterApp;

public partial class MainWindow
{
    private void Window_SourceInitialized(object? sender, EventArgs e)
    {
        SizeToComfortableWorkArea();
        ApplyThemedComboBoxTemplates();
        RefreshThemeButton();
        ThemeService.ApplyWindowChrome(this);
    }

    private void SizeToComfortableWorkArea()
    {
        var workArea = SystemParameters.WorkArea;

        Width = Math.Clamp(workArea.Width * 0.58, 900, 1180);
        Height = Math.Clamp(workArea.Height * 0.66, 560, 760);
        Left = workArea.Left + ((workArea.Width - Width) / 2);
        Top = workArea.Top + ((workArea.Height - Height) / 2);
    }

    private void Preferences_Click(object sender, RoutedEventArgs e)
    {
        PreferencesPopup.IsOpen = true;
    }

    private void PreferencesClose_Click(object sender, RoutedEventArgs e)
    {
        PreferencesPopup.IsOpen = false;
    }

    private void Theme_Click(object sender, RoutedEventArgs e)
    {
        ThemeService.Toggle();
        ApplyThemedComboBoxTemplates();
        RefreshThemeButton();
        ThemeService.ApplyWindowChrome(this);
        StatusText.Text = $"{ThemeService.Current} theme enabled.";
    }

    private void ApplyThemedComboBoxTemplates()
    {
        if (TryFindResource("ThemedComboBoxTemplate") is not ControlTemplate template)
        {
            return;
        }

        foreach (var combo in FindLogicalChildren<ComboBox>(this))
        {
            combo.Template = template;
        }
    }

    private static IEnumerable<T> FindLogicalChildren<T>(DependencyObject root)
        where T : DependencyObject
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root))
        {
            if (child is not DependencyObject dependencyObject)
            {
                continue;
            }

            if (dependencyObject is T match)
            {
                yield return match;
            }

            foreach (var nested in FindLogicalChildren<T>(dependencyObject))
            {
                yield return nested;
            }
        }
    }

    private void RefreshThemeButton()
    {
        ThemeButton.Content = ThemeService.Current == UiTheme.Dark
            ? "Theme: Dark"
            : "Theme: Light";
    }
}

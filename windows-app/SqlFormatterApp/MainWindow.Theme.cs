using System.Windows;

namespace SqlFormatterApp;

public partial class MainWindow
{
    private void Window_SourceInitialized(object? sender, EventArgs e)
    {
        RefreshThemeButton();
        ThemeService.ApplyWindowChrome(this);
    }

    private void Theme_Click(object sender, RoutedEventArgs e)
    {
        ThemeService.Toggle();
        RefreshThemeButton();
        ThemeService.ApplyWindowChrome(this);
        StatusText.Text = $"{ThemeService.Current} theme enabled.";
    }

    private void RefreshThemeButton()
    {
        ThemeButton.Content = ThemeService.Current == UiTheme.Dark
            ? "Theme: Dark"
            : "Theme: Light";
    }
}

using System.Windows;

namespace SqlFormatterApp;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        ThemeService.ApplySavedTheme();
        base.OnStartup(e);
    }
}

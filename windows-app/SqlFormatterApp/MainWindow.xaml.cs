using Microsoft.Win32;
using System.IO;
using System.Windows;
using System.Windows.Input;

namespace SqlFormatterApp;

public partial class MainWindow : Window
{
    private readonly FormatterService _formatter = new();

    public MainWindow()
    {
        InitializeComponent();
        WidthBox.Text = FormatterSettings.ReadMaxLineLength().ToString();
        StatusText.Text = _formatter.IsAvailable
            ? "Ready"
            : "Formatter scripts were not found next to the app.";
        UpdateStats();
    }

    private async void Format_Click(object sender, RoutedEventArgs e)
    {
        await FormatCurrentAsync();
    }

    private async Task FormatCurrentAsync()
    {
        var input = InputBox.Text;
        if (string.IsNullOrWhiteSpace(input))
        {
            StatusText.Text = "Paste or open SQL/SPARQL first.";
            return;
        }

        if (!TryApplyWidth())
        {
            return;
        }

        DialectText.Text = $"Dialect: {DialectDetector.Detect(input)}";
        FormatButton.IsEnabled = false;
        StatusText.Text = "Formatting...";

        try
        {
            var result = await _formatter.FormatAsync(input);
            if (!result.Success)
            {
                StatusText.Text = "Formatting failed.";
                MessageBox.Show(
                    this,
                    result.ErrorMessage ?? "The formatter returned an unknown error.",
                    "SQL Formatter",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
                return;
            }

            OutputBox.Text = result.Output;
            UpdateStats();
            StatusText.Text = $"Formatted successfully in {result.ElapsedMilliseconds:N0} ms.";
        }
        catch (Exception ex)
        {
            StatusText.Text = "Formatting failed.";
            MessageBox.Show(this, ex.Message, "SQL Formatter", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            FormatButton.IsEnabled = true;
        }
    }

    private bool TryApplyWidth()
    {
        if (!int.TryParse(WidthBox.Text.Trim(), out var width) || width < 60 || width > 400)
        {
            MessageBox.Show(
                this,
                "Max width must be a whole number from 60 to 400.",
                "SQL Formatter",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            WidthBox.Focus();
            WidthBox.SelectAll();
            return false;
        }

        FormatterSettings.WriteMaxLineLength(width);
        return true;
    }

    private void Open_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Open SQL or SPARQL",
            Filter = "SQL / SPARQL|*.sql;*.sparql;*.rq;*.ru|All files|*.*",
            CheckFileExists = true
        };

        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        InputBox.Text = File.ReadAllText(dialog.FileName);
        DialectText.Text = $"Dialect: {DialectDetector.Detect(InputBox.Text)}";
        StatusText.Text = $"Opened {Path.GetFileName(dialog.FileName)}";
    }

    private void SaveOutput_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(OutputBox.Text))
        {
            StatusText.Text = "There is no formatted output to save.";
            return;
        }

        var dialect = DialectDetector.Detect(InputBox.Text);
        var extension = dialect == "SPARQL" ? ".sparql" : ".sql";
        var dialog = new SaveFileDialog
        {
            Title = "Save formatted output",
            Filter = dialect == "SPARQL" ? "SPARQL|*.sparql;*.rq|All files|*.*" : "SQL|*.sql|All files|*.*",
            DefaultExt = extension,
            AddExtension = true,
            FileName = $"formatted{extension}"
        };

        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        File.WriteAllText(dialog.FileName, OutputBox.Text);
        StatusText.Text = $"Saved {Path.GetFileName(dialog.FileName)}";
    }

    private void CopyOutput_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(OutputBox.Text))
        {
            StatusText.Text = "There is no formatted output to copy.";
            return;
        }

        Clipboard.SetText(OutputBox.Text);
        StatusText.Text = "Formatted output copied to clipboard.";
    }

    private void ReplaceInput_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(OutputBox.Text))
        {
            StatusText.Text = "There is no formatted output yet.";
            return;
        }

        InputBox.Text = OutputBox.Text;
        InputBox.Focus();
        InputBox.CaretIndex = InputBox.Text.Length;
        StatusText.Text = "Input replaced with formatted output.";
    }

    private void Clear_Click(object sender, RoutedEventArgs e)
    {
        InputBox.Clear();
        OutputBox.Clear();
        DialectText.Text = "Dialect: Auto";
        StatusText.Text = "Ready";
        InputBox.Focus();
    }

    private void InputBox_TextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(InputBox.Text))
        {
            DialectText.Text = $"Dialect: {DialectDetector.Detect(InputBox.Text)}";
        }
        else
        {
            DialectText.Text = "Dialect: Auto";
        }
        UpdateStats();
    }

    private void UpdateStats()
    {
        InputStatsText.Text = DescribeText(InputBox.Text);
        OutputStatsText.Text = DescribeText(OutputBox.Text);
    }

    private static string DescribeText(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return "0 chars • 0 lines";
        }

        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n').Length;
        return $"{text.Length:N0} chars • {lines:N0} lines";
    }

    private async void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
        {
            e.Handled = true;
            await FormatCurrentAsync();
        }
        else if (e.Key == Key.S && Keyboard.Modifiers.HasFlag(ModifierKeys.Control) && Keyboard.Modifiers.HasFlag(ModifierKeys.Shift))
        {
            e.Handled = true;
            SaveOutput_Click(this, new RoutedEventArgs());
        }
    }
}

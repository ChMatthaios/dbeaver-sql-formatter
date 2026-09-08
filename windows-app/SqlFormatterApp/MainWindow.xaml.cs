using Microsoft.Win32;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace SqlFormatterApp;

public partial class MainWindow : Window
{
    private readonly FormatterService _formatter = new();
    private bool _loadingSettings;

    public MainWindow()
    {
        InitializeComponent();
        PopulateDynamicCombos();
        LoadSettingsIntoUi();
        StatusText.Text = _formatter.IsAvailable
            ? "Ready"
            : "Formatter scripts were not found next to the app.";
        UpdateStats();
    }

    private void PopulateDynamicCombos()
    {
        foreach (var combo in new[]
                 {
                     SelectListCombo, GroupByListCombo, OrderByListCombo, UpdateSetListCombo,
                     InsertColumnsListCombo, ValuesListCombo, InListCombo, FunctionArgsListCombo
                 })
        {
            combo.Items.Clear();
            combo.Items.Add(Item("Preserve current layout", "Preserve"));
            combo.Items.Add(Item("Compact when it fits", "Compact"));
            combo.Items.Add(Item("Wrap at max width", "Wrap"));
            combo.Items.Add(Item("One item per line", "OnePerLine"));
        }
    }

    private static ComboBoxItem Item(string content, string tag) =>
        new() { Content = content, Tag = tag };

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

        if (!TryApplySettings(out _))
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

    private void LoadSettingsIntoUi()
    {
        _loadingSettings = true;
        try
        {
            var settings = FormatterSettings.Read();
            WidthBox.Text = settings.MaxLineLength.ToString();
            SelectTag(IndentCombo, settings.IndentSize.ToString());
            SelectTag(KeywordCasingCombo, settings.KeywordCasing);
            PreserveCommentsCheckBox.IsChecked = settings.PreserveCommentLineBoundaries;
            AdvancedEnabledCheckBox.IsChecked = settings.Advanced.Enabled;

            var p = settings.Advanced.Parentheses;
            SelectTag(FunctionParenSpaceCombo, p.FunctionSpaceBeforeParen);
            SelectTag(InsideParenCombo, p.InsideParentheses);
            SelectTag(SubqueryOpeningCombo, p.SubqueryOpening);
            SelectTag(SubqueryClosingCombo, p.SubqueryClosing);
            SelectTag(CteParenCombo, p.CteAsParenthesis);

            var l = settings.Advanced.Lists;
            SelectTag(SelectListCombo, l.Select);
            SelectTag(GroupByListCombo, l.GroupBy);
            SelectTag(OrderByListCombo, l.OrderBy);
            SelectTag(UpdateSetListCombo, l.UpdateSet);
            SelectTag(InsertColumnsListCombo, l.InsertColumns);
            SelectTag(ValuesListCombo, l.Values);
            SelectTag(InListCombo, l.InList);
            SelectTag(FunctionArgsListCombo, l.FunctionArguments);
            SelectTag(CommaStyleCombo, l.CommaStyle);
            SelectTag(ContinuationIndentCombo, l.ContinuationIndent);

            var c = settings.Advanced.Clauses;
            SelectTag(ClauseAlignmentCombo, c.Alignment);
            SelectTag(BooleanPositionCombo, c.BooleanOperatorPosition);
            SelectTag(JoinLayoutCombo, c.JoinLayout);
            SelectTag(OnClauseCombo, c.OnClause);
            SelectTag(CteLayoutCombo, c.CteLayout);
            BlankLineBetweenCtesCheckBox.IsChecked = c.BlankLineBetweenCtes;

            var k = settings.Advanced.Case;
            SelectTag(CaseStyleCombo, k.Style);
            SelectTag(ThenResultCombo, k.ThenResult);
            SelectTag(ElseResultCombo, k.ElseResult);

            var s = settings.Advanced.Spacing;
            SelectTag(ComparisonSpacingCombo, s.ComparisonOperators);
            SelectTag(AfterCommaCombo, s.AfterComma);

            SelectTag(PresetCombo, "Custom");
            SettingsModeText.Text = "Custom";
            UpdateSettingsSummary(settings);
        }
        finally
        {
            _loadingSettings = false;
        }
    }

    private bool TryApplySettings(out FormatterPreferences preferences)
    {
        preferences = FormatterSettings.CreateDefaults();

        if (!int.TryParse(WidthBox.Text.Trim(), out var width) || width < 60 || width > 400)
        {
            MessageBox.Show(
                this,
                "Max line width must be a whole number from 60 to 400.",
                "SQL Formatter",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            WidthBox.Focus();
            WidthBox.SelectAll();
            return false;
        }

        var indentSize = GetTag(IndentCombo) == "4" ? 4 : 2;
        var keywordCasing = GetTag(KeywordCasingCombo, "Uppercase");

        preferences = new FormatterPreferences
        {
            MaxLineLength = width,
            IndentSize = indentSize,
            KeywordCasing = keywordCasing,
            PreserveCommentLineBoundaries = PreserveCommentsCheckBox.IsChecked == true,
            Advanced = new AdvancedBeautifierPreferences
            {
                Enabled = AdvancedEnabledCheckBox.IsChecked == true,
                Parentheses = new ParenthesisPreferences
                {
                    FunctionSpaceBeforeParen = GetTag(FunctionParenSpaceCombo),
                    InsideParentheses = GetTag(InsideParenCombo),
                    SubqueryOpening = GetTag(SubqueryOpeningCombo),
                    SubqueryClosing = GetTag(SubqueryClosingCombo),
                    CteAsParenthesis = GetTag(CteParenCombo)
                },
                Lists = new ListPreferences
                {
                    Select = GetTag(SelectListCombo),
                    GroupBy = GetTag(GroupByListCombo),
                    OrderBy = GetTag(OrderByListCombo),
                    UpdateSet = GetTag(UpdateSetListCombo),
                    InsertColumns = GetTag(InsertColumnsListCombo),
                    Values = GetTag(ValuesListCombo),
                    InList = GetTag(InListCombo),
                    FunctionArguments = GetTag(FunctionArgsListCombo),
                    CommaStyle = GetTag(CommaStyleCombo),
                    ContinuationIndent = GetTag(ContinuationIndentCombo)
                },
                Clauses = new ClausePreferences
                {
                    Alignment = GetTag(ClauseAlignmentCombo),
                    BooleanOperatorPosition = GetTag(BooleanPositionCombo),
                    JoinLayout = GetTag(JoinLayoutCombo),
                    OnClause = GetTag(OnClauseCombo),
                    CteLayout = GetTag(CteLayoutCombo),
                    BlankLineBetweenCtes = BlankLineBetweenCtesCheckBox.IsChecked == true
                },
                Case = new CasePreferences
                {
                    Style = GetTag(CaseStyleCombo),
                    ThenResult = GetTag(ThenResultCombo),
                    ElseResult = GetTag(ElseResultCombo)
                },
                Spacing = new SpacingPreferences
                {
                    ComparisonOperators = GetTag(ComparisonSpacingCombo),
                    AfterComma = GetTag(AfterCommaCombo)
                }
            }
        };

        try
        {
            FormatterSettings.Write(preferences);
            UpdateSettingsSummary(preferences);
            return true;
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                this,
                $"Could not save formatter settings.\n\n{ex.Message}",
                "SQL Formatter",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            return false;
        }
    }

    private void UpdateSettingsSummary(FormatterPreferences settings)
    {
        var advancedCount = CountAdvancedRules(settings.Advanced);
        var casing = settings.KeywordCasing switch
        {
            "Lowercase" => "lowercase",
            "Preserve" => "preserve case",
            _ => "UPPERCASE"
        };
        SettingsSummaryText.Text = settings.Advanced.Enabled
            ? $"{settings.MaxLineLength} cols • {settings.IndentSize}-space indent • {casing}\n{advancedCount} explicit advanced rule{(advancedCount == 1 ? "" : "s")}"
            : $"{settings.MaxLineLength} cols • {settings.IndentSize}-space indent • {casing}\nAdvanced beautifier disabled";
    }

    private static int CountAdvancedRules(AdvancedBeautifierPreferences a)
    {
        var values = new[]
        {
            a.Parentheses.FunctionSpaceBeforeParen, a.Parentheses.InsideParentheses,
            a.Parentheses.SubqueryOpening, a.Parentheses.SubqueryClosing, a.Parentheses.CteAsParenthesis,
            a.Lists.Select, a.Lists.GroupBy, a.Lists.OrderBy, a.Lists.UpdateSet, a.Lists.InsertColumns,
            a.Lists.Values, a.Lists.InList, a.Lists.FunctionArguments, a.Lists.CommaStyle, a.Lists.ContinuationIndent,
            a.Clauses.Alignment, a.Clauses.BooleanOperatorPosition, a.Clauses.JoinLayout, a.Clauses.OnClause,
            a.Clauses.CteLayout, a.Case.Style, a.Case.ThenResult, a.Case.ElseResult,
            a.Spacing.ComparisonOperators, a.Spacing.AfterComma
        };
        return values.Count(v => !string.Equals(v, "Preserve", StringComparison.OrdinalIgnoreCase))
               + (a.Clauses.BlankLineBetweenCtes ? 1 : 0);
    }

    private void ApplySettings_Click(object sender, RoutedEventArgs e)
    {
        if (TryApplySettings(out _))
        {
            SettingsModeText.Text = GetTag(PresetCombo, "Custom") == "Custom"
                ? "Custom"
                : ((ComboBoxItem?)PresetCombo.SelectedItem)?.Content?.ToString() ?? "Custom";
            StatusText.Text = "Formatter settings saved.";
        }
    }

    private void ResetSettings_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            FormatterSettings.ResetToDefaults();
            LoadSettingsIntoUi();
            StatusText.Text = "Formatter settings reset to defaults.";
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                this,
                $"Could not reset formatter settings.\n\n{ex.Message}",
                "SQL Formatter",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void PresetCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loadingSettings || PresetCombo.SelectedItem is not ComboBoxItem selected)
        {
            return;
        }

        var preset = selected.Tag?.ToString() ?? "Custom";
        if (preset == "Custom")
        {
            SettingsModeText.Text = "Custom";
            return;
        }

        ApplyPresetToUi(preset);
        SettingsModeText.Text = selected.Content?.ToString() ?? preset;
    }

    private void ApplyPresetToUi(string preset)
    {
        _loadingSettings = true;
        try
        {
            AdvancedEnabledCheckBox.IsChecked = true;
            SetAllAdvancedToPreserve();

            switch (preset)
            {
                case "Preserve":
                    break;

                case "IBMExpanded":
                    WidthBox.Text = "120";
                    SelectTag(IndentCombo, "2");
                    SelectTag(KeywordCasingCombo, "Uppercase");
                    SelectTag(SelectListCombo, "OnePerLine");
                    SelectTag(GroupByListCombo, "OnePerLine");
                    SelectTag(OrderByListCombo, "Wrap");
                    SelectTag(UpdateSetListCombo, "OnePerLine");
                    SelectTag(InsertColumnsListCombo, "OnePerLine");
                    SelectTag(InListCombo, "Wrap");
                    SelectTag(CommaStyleCombo, "Trailing");
                    SelectTag(ContinuationIndentCombo, "Align");
                    SelectTag(ClauseAlignmentCombo, "IBM");
                    SelectTag(BooleanPositionCombo, "Leading");
                    SelectTag(JoinLayoutCombo, "EachNewLine");
                    SelectTag(OnClauseCombo, "NewLine");
                    SelectTag(CteLayoutCombo, "ExpandedHeader");
                    SelectTag(CaseStyleCombo, "Multiline");
                    SelectTag(ThenResultCombo, "NewLine");
                    break;

                case "SqlPrompt":
                    WidthBox.Text = "120";
                    SelectTag(IndentCombo, "4");
                    SelectTag(KeywordCasingCombo, "Uppercase");
                    SelectTag(FunctionParenSpaceCombo, "NoSpace");
                    SelectTag(InsideParenCombo, "NoSpace");
                    SelectTag(SubqueryOpeningCombo, "NewLine");
                    SelectTag(SubqueryClosingCombo, "NewLine");
                    SelectTag(CteParenCombo, "SameLine");
                    SelectTag(SelectListCombo, "OnePerLine");
                    SelectTag(GroupByListCombo, "OnePerLine");
                    SelectTag(OrderByListCombo, "OnePerLine");
                    SelectTag(UpdateSetListCombo, "OnePerLine");
                    SelectTag(InsertColumnsListCombo, "OnePerLine");
                    SelectTag(ValuesListCombo, "Wrap");
                    SelectTag(InListCombo, "Wrap");
                    SelectTag(FunctionArgsListCombo, "Wrap");
                    SelectTag(CommaStyleCombo, "Trailing");
                    SelectTag(ContinuationIndentCombo, "Indent");
                    SelectTag(ClauseAlignmentCombo, "Left");
                    SelectTag(BooleanPositionCombo, "Leading");
                    SelectTag(JoinLayoutCombo, "EachNewLine");
                    SelectTag(OnClauseCombo, "NewLine");
                    SelectTag(CteLayoutCombo, "CompactHeader");
                    SelectTag(CaseStyleCombo, "Multiline");
                    SelectTag(ThenResultCombo, "SameLine");
                    SelectTag(ElseResultCombo, "SameLine");
                    SelectTag(ComparisonSpacingCombo, "Spaced");
                    SelectTag(AfterCommaCombo, "Space");
                    break;

                case "Compact":
                    WidthBox.Text = "120";
                    SelectTag(IndentCombo, "2");
                    SelectTag(FunctionParenSpaceCombo, "NoSpace");
                    SelectTag(InsideParenCombo, "NoSpace");
                    SelectTag(SubqueryOpeningCombo, "SameLine");
                    SelectTag(SubqueryClosingCombo, "SameLine");
                    SelectTag(CteParenCombo, "SameLine");
                    foreach (var combo in new[]
                             {
                                 SelectListCombo, GroupByListCombo, OrderByListCombo, UpdateSetListCombo,
                                 InsertColumnsListCombo, ValuesListCombo, InListCombo, FunctionArgsListCombo
                             })
                    {
                        SelectTag(combo, "Compact");
                    }
                    SelectTag(CommaStyleCombo, "Trailing");
                    SelectTag(ClauseAlignmentCombo, "Left");
                    SelectTag(BooleanPositionCombo, "Leading");
                    SelectTag(JoinLayoutCombo, "CompactWhenPossible");
                    SelectTag(OnClauseCombo, "SameLine");
                    SelectTag(CteLayoutCombo, "CompactHeader");
                    SelectTag(CaseStyleCombo, "CompactShort");
                    SelectTag(ComparisonSpacingCombo, "Spaced");
                    SelectTag(AfterCommaCombo, "Space");
                    break;
            }
        }
        finally
        {
            _loadingSettings = false;
        }
    }

    private void SetAllAdvancedToPreserve()
    {
        foreach (var combo in new[]
                 {
                     FunctionParenSpaceCombo, InsideParenCombo, SubqueryOpeningCombo, SubqueryClosingCombo, CteParenCombo,
                     SelectListCombo, GroupByListCombo, OrderByListCombo, UpdateSetListCombo, InsertColumnsListCombo,
                     ValuesListCombo, InListCombo, FunctionArgsListCombo, CommaStyleCombo, ContinuationIndentCombo,
                     ClauseAlignmentCombo, BooleanPositionCombo, JoinLayoutCombo, OnClauseCombo, CteLayoutCombo,
                     CaseStyleCombo, ThenResultCombo, ElseResultCombo, ComparisonSpacingCombo, AfterCommaCombo
                 })
        {
            SelectTag(combo, "Preserve");
        }
        BlankLineBetweenCtesCheckBox.IsChecked = false;
    }

    private static string GetTag(ComboBox combo, string fallback = "Preserve") =>
        combo.SelectedItem is ComboBoxItem item && item.Tag is not null
            ? item.Tag.ToString() ?? fallback
            : fallback;

    private static void SelectTag(ComboBox combo, string tag)
    {
        foreach (var raw in combo.Items)
        {
            if (raw is ComboBoxItem item && string.Equals(item.Tag?.ToString(), tag, StringComparison.OrdinalIgnoreCase))
            {
                combo.SelectedItem = item;
                return;
            }
        }
        if (combo.Items.Count > 0)
        {
            combo.SelectedIndex = 0;
        }
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

    private void InputBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        DialectText.Text = string.IsNullOrWhiteSpace(InputBox.Text)
            ? "Dialect: Auto"
            : $"Dialect: {DialectDetector.Detect(InputBox.Text)}";
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

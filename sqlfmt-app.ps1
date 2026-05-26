<#
SQLFMT GUI - WPF desktop wrapper.

Rules:
- This file does not contain formatter logic.
- It calls format-sql.ps1 through stdin/stdout.
- DBeaver, CLI, file runner, and GUI must all use the same formatter engine.
- Place this file next to format-sql.ps1 in the repository root.
#>

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$script:RootDir = $PSScriptRoot
$script:FormatterPath = Join-Path $script:RootDir "format-sql.ps1"
$script:CurrentFilePath = $null
$script:IsDarkTheme = $true

$script:SettingsDir = Join-Path $env:APPDATA "SQLFMT"
$script:SettingsPath = Join-Path $script:SettingsDir "settings.json"

$script:Settings = [ordered]@{
    profile = "Default"
    theme = "Dark"

    # Stored now, applied to format-sql.ps1 later.
    maxLineLength = 120
    indentSize = 2
    useTabs = $false
    keywordCasing = "Uppercase"
    commaStyle = "Trailing"
    selectColumns = "OnePerLine"
    joinAlignment = "ClauseColumn"
    whereAlignment = "ConditionText"
    caseStyle = "Expanded"
    preserveCommentLineBoundaries = $true
}

function Save-Settings {
    if (-not (Test-Path $script:SettingsDir)) {
        New-Item -ItemType Directory -Force -Path $script:SettingsDir | Out-Null
    }

    ($script:Settings | ConvertTo-Json -Depth 8) |
        Set-Content -Path $script:SettingsPath -Encoding UTF8
}

function Load-Settings {
    if (-not (Test-Path $script:SettingsPath)) {
        Save-Settings
        return
    }

    try {
        $loaded = Get-Content -Path $script:SettingsPath -Raw | ConvertFrom-Json

        foreach ($key in @($script:Settings.Keys)) {
            if ($loaded.PSObject.Properties.Name -contains $key) {
                $script:Settings[$key] = $loaded.$key
            }
        }
    }
    catch {
        Save-Settings
    }
}

Load-Settings
$script:IsDarkTheme = ($script:Settings.theme -eq "Dark")

if (-not (Test-Path $script:FormatterPath)) {
    [System.Windows.MessageBox]::Show(
        "format-sql.ps1 was not found next to this GUI script.`n`nExpected:`n$script:FormatterPath",
        "SQLFMT GUI",
        "OK",
        "Error"
    ) | Out-Null
    exit 1
}

function Invoke-SqlFormatter {
    param([string]$Sql)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:FormatterPath`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()

    $process.StandardInput.Write($Sql)
    $process.StandardInput.Close()

    $output = $process.StandardOutput.ReadToEnd()
    $errorOutput = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        throw "Formatter failed with exit code $($process.ExitCode):`n$errorOutput"
    }

    return $output
}

$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SQLFMT - DB2 SQL Formatter"
        Width="1400"
        Height="820"
        MinWidth="1050"
        MinHeight="650"
        WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI"
        Background="#111827">
    <Window.Resources>
        <Style x:Key="SoftButton" TargetType="Button">
            <Setter Property="Height" Value="34"/>
            <Setter Property="MinWidth" Value="96"/>
            <Setter Property="Margin" Value="0,0,10,0"/>
            <Setter Property="Padding" Value="14,4"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Background" Value="#2563EB"/>
            <Setter Property="Foreground" Value="#F9FAFB"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource SoftButton}">
            <Setter Property="Background" Value="#374151"/>
        </Style>
        <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource SoftButton}">
            <Setter Property="Background" Value="#B91C1C"/>
        </Style>
        <Style x:Key="EditorBox" TargetType="TextBox">
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="AcceptsReturn" Value="True"/>
            <Setter Property="AcceptsTab" Value="True"/>
            <Setter Property="TextWrapping" Value="NoWrap"/>
            <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
            <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="12"/>
        </Style>
    </Window.Resources>

    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <DockPanel Grid.Row="0" Margin="0,0,0,14">
            <StackPanel DockPanel.Dock="Left">
                <TextBlock x:Name="TitleText" Text="SQLFMT" FontSize="28" FontWeight="Bold" Foreground="#F9FAFB"/>
                <TextBlock x:Name="SubtitleText" Text="DB2 SQL Formatter - standalone wrapper around format-sql.ps1" FontSize="13" Foreground="#9CA3AF"/>
            </StackPanel>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="SettingsButton" Style="{StaticResource SecondaryButton}" Content="Settings"/>
                <Button x:Name="ThemeButton" Style="{StaticResource SecondaryButton}" Content="Light theme"/>
                <Button x:Name="AboutButton" Style="{StaticResource SecondaryButton}" Content="About"/>
            </StackPanel>
        </DockPanel>

        <DockPanel Grid.Row="1" Margin="0,0,0,14">
            <Button x:Name="OpenButton" Style="{StaticResource SecondaryButton}" Content="Open SQL"/>
            <Button x:Name="FormatButton" Style="{StaticResource SoftButton}" Content="Format"/>
            <Button x:Name="CopyButton" Style="{StaticResource SecondaryButton}" Content="Copy Output"/>
            <Button x:Name="SaveButton" Style="{StaticResource SecondaryButton}" Content="Save Output"/>
            <Button x:Name="ReplaceButton" Style="{StaticResource DangerButton}" Content="Replace File"/>
            <Button x:Name="ClearButton" Style="{StaticResource SecondaryButton}" Content="Clear"/>
        </DockPanel>

        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="14"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Border x:Name="InputPanel" Grid.Column="0" CornerRadius="14" Padding="12" Background="#1F2937">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <TextBlock x:Name="InputLabel" Text="Input SQL" FontWeight="Bold" FontSize="14" Foreground="#E5E7EB" Margin="0,0,0,8"/>
                    <TextBox x:Name="InputBox" Grid.Row="1" Style="{StaticResource EditorBox}"/>
                </Grid>
            </Border>

            <Border x:Name="OutputPanel" Grid.Column="2" CornerRadius="14" Padding="12" Background="#1F2937">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <TextBlock x:Name="OutputLabel" Text="Formatted SQL" FontWeight="Bold" FontSize="14" Foreground="#E5E7EB" Margin="0,0,0,8"/>
                    <TextBox x:Name="OutputBox" Grid.Row="1" Style="{StaticResource EditorBox}"/>
                </Grid>
            </Border>
        </Grid>

        <DockPanel Grid.Row="3" Margin="0,14,0,0">
            <TextBlock x:Name="StatusText" DockPanel.Dock="Left" Text="Ready." Foreground="#9CA3AF" FontSize="12"/>
            <TextBlock x:Name="PathText" DockPanel.Dock="Right" Text="" Foreground="#6B7280" FontSize="12" TextAlignment="Right"/>
        </DockPanel>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$names = @(
    "TitleText", "SettingsButton", "SubtitleText", "ThemeButton", "AboutButton",
    "OpenButton", "FormatButton", "CopyButton", "SaveButton", "ReplaceButton", "ClearButton",
    "InputPanel", "OutputPanel", "InputLabel", "OutputLabel", "InputBox", "OutputBox",
    "StatusText", "PathText"
)

$ui = @{}
foreach ($name in $names) {
    $ui[$name] = $window.FindName($name)
}

function New-Brush {
    param([string]$Hex)
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

function Set-Status {
    param([string]$Text)
    $ui.StatusText.Text = $Text
}

function Set-Theme {
    param([bool]$Dark)

    $script:IsDarkTheme = $Dark
    $script:Settings.theme = if ($Dark) { "Dark" } else { "Light" }
    Save-Settings

    if ($Dark) {
        $window.Background = New-Brush "#111827"
        $ui.TitleText.Foreground = New-Brush "#F9FAFB"
        $ui.SubtitleText.Foreground = New-Brush "#9CA3AF"
        $ui.InputPanel.Background = New-Brush "#1F2937"
        $ui.OutputPanel.Background = New-Brush "#1F2937"
        $ui.InputLabel.Foreground = New-Brush "#E5E7EB"
        $ui.OutputLabel.Foreground = New-Brush "#E5E7EB"
        $ui.InputBox.Background = New-Brush "#0B1220"
        $ui.OutputBox.Background = New-Brush "#0B1220"
        $ui.InputBox.Foreground = New-Brush "#E5E7EB"
        $ui.OutputBox.Foreground = New-Brush "#E5E7EB"
        $ui.InputBox.BorderBrush = New-Brush "#374151"
        $ui.OutputBox.BorderBrush = New-Brush "#374151"
        $ui.StatusText.Foreground = New-Brush "#9CA3AF"
        $ui.PathText.Foreground = New-Brush "#6B7280"
        $ui.ThemeButton.Content = "Light theme"
    }
    else {
        $window.Background = New-Brush "#F3F4F6"
        $ui.TitleText.Foreground = New-Brush "#111827"
        $ui.SubtitleText.Foreground = New-Brush "#4B5563"
        $ui.InputPanel.Background = New-Brush "#FFFFFF"
        $ui.OutputPanel.Background = New-Brush "#FFFFFF"
        $ui.InputLabel.Foreground = New-Brush "#111827"
        $ui.OutputLabel.Foreground = New-Brush "#111827"
        $ui.InputBox.Background = New-Brush "#FAFAFA"
        $ui.OutputBox.Background = New-Brush "#FAFAFA"
        $ui.InputBox.Foreground = New-Brush "#111827"
        $ui.OutputBox.Foreground = New-Brush "#111827"
        $ui.InputBox.BorderBrush = New-Brush "#D1D5DB"
        $ui.OutputBox.BorderBrush = New-Brush "#D1D5DB"
        $ui.StatusText.Foreground = New-Brush "#4B5563"
        $ui.PathText.Foreground = New-Brush "#6B7280"
        $ui.ThemeButton.Content = "Dark theme"
    }
}

$ui.PathText.Text = "Formatter: $script:FormatterPath"
Set-Theme -Dark $true

function Select-ComboValue {
    param(
        $Combo,
        [string]$Value
    )

    foreach ($item in $Combo.Items) {
        if ($item.Content -eq $Value) {
            $Combo.SelectedItem = $item
            return
        }
    }

    $Combo.SelectedIndex = 0
}

function New-SettingsWindow {
    $settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SQLFMT Settings"
        Width="560"
        Height="650"
        MinWidth="520"
        MinHeight="560"
        WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize"
        FontFamily="Segoe UI"
        Background="#111827">
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="0,0,0,16">
            <TextBlock Text="Formatter Preferences"
                       FontSize="22"
                       FontWeight="Bold"
                       Foreground="#F9FAFB"/>
            <TextBlock Text="Saved per Windows user. Formatter behavior will be wired in later commits."
                       Foreground="#9CA3AF"
                       Margin="0,4,0,0"/>
        </StackPanel>

        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="220"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <Grid.RowDefinitions>
                    <RowDefinition Height="42"/>
                    <RowDefinition Height="42"/>
                    <RowDefinition Height="42"/>
                    <RowDefinition Height="42"/>
                    <RowDefinition Height="42"/>
                    <RowDefinition Height="42"/>
                    <RowDefinition Height="42"/>
                    <RowDefinition Height="42"/>
                    <RowDefinition Height="42"/>
                    <RowDefinition Height="42"/>
                    <RowDefinition Height="42"/>
                </Grid.RowDefinitions>

                <TextBlock Grid.Row="0" Grid.Column="0" Text="Profile" Foreground="#E5E7EB" VerticalAlignment="Center"/>
                <ComboBox x:Name="ProfileBox" Grid.Row="0" Grid.Column="1" Height="28">
                    <ComboBoxItem Content="Default"/>
                    <ComboBoxItem Content="Compact"/>
                    <ComboBoxItem Content="Wide"/>
                    <ComboBoxItem Content="Custom"/>
                </ComboBox>

                <TextBlock Grid.Row="1" Grid.Column="0" Text="Theme" Foreground="#E5E7EB" VerticalAlignment="Center"/>
                <ComboBox x:Name="ThemeBox" Grid.Row="1" Grid.Column="1" Height="28">
                    <ComboBoxItem Content="Dark"/>
                    <ComboBoxItem Content="Light"/>
                </ComboBox>

                <TextBlock Grid.Row="2" Grid.Column="0" Text="Max line length" Foreground="#E5E7EB" VerticalAlignment="Center"/>
                <ComboBox x:Name="MaxLineBox" Grid.Row="2" Grid.Column="1" Height="28">
                    <ComboBoxItem Content="80"/>
                    <ComboBoxItem Content="100"/>
                    <ComboBoxItem Content="120"/>
                    <ComboBoxItem Content="160"/>
                </ComboBox>

                <TextBlock Grid.Row="3" Grid.Column="0" Text="Indent size" Foreground="#E5E7EB" VerticalAlignment="Center"/>
                <ComboBox x:Name="IndentBox" Grid.Row="3" Grid.Column="1" Height="28">
                    <ComboBoxItem Content="2"/>
                    <ComboBoxItem Content="4"/>
                </ComboBox>

                <TextBlock Grid.Row="4" Grid.Column="0" Text="Keyword casing" Foreground="#E5E7EB" VerticalAlignment="Center"/>
                <ComboBox x:Name="KeywordBox" Grid.Row="4" Grid.Column="1" Height="28">
                    <ComboBoxItem Content="Uppercase"/>
                    <ComboBoxItem Content="Lowercase"/>
                    <ComboBoxItem Content="Preserve"/>
                </ComboBox>

                <TextBlock Grid.Row="5" Grid.Column="0" Text="Comma style" Foreground="#E5E7EB" VerticalAlignment="Center"/>
                <ComboBox x:Name="CommaBox" Grid.Row="5" Grid.Column="1" Height="28">
                    <ComboBoxItem Content="Trailing"/>
                    <ComboBoxItem Content="Leading"/>
                </ComboBox>

                <TextBlock Grid.Row="6" Grid.Column="0" Text="SELECT columns" Foreground="#E5E7EB" VerticalAlignment="Center"/>
                <ComboBox x:Name="SelectColumnsBox" Grid.Row="6" Grid.Column="1" Height="28">
                    <ComboBoxItem Content="OnePerLine"/>
                    <ComboBoxItem Content="PreserveIfShort"/>
                </ComboBox>

                <TextBlock Grid.Row="7" Grid.Column="0" Text="JOIN alignment" Foreground="#E5E7EB" VerticalAlignment="Center"/>
                <ComboBox x:Name="JoinBox" Grid.Row="7" Grid.Column="1" Height="28">
                    <ComboBoxItem Content="ClauseColumn"/>
                    <ComboBoxItem Content="IndentOneLevel"/>
                </ComboBox>

                <TextBlock Grid.Row="8" Grid.Column="0" Text="WHERE alignment" Foreground="#E5E7EB" VerticalAlignment="Center"/>
                <ComboBox x:Name="WhereBox" Grid.Row="8" Grid.Column="1" Height="28">
                    <ComboBoxItem Content="ConditionText"/>
                    <ComboBoxItem Content="OperatorColumn"/>
                </ComboBox>

                <TextBlock Grid.Row="9" Grid.Column="0" Text="CASE style" Foreground="#E5E7EB" VerticalAlignment="Center"/>
                <ComboBox x:Name="CaseBox" Grid.Row="9" Grid.Column="1" Height="28">
                    <ComboBoxItem Content="Expanded"/>
                    <ComboBoxItem Content="PreserveShort"/>
                </ComboBox>

                <CheckBox x:Name="CommentBoundaryBox"
                          Grid.Row="10"
                          Grid.ColumnSpan="2"
                          Content="Preserve comment line boundaries"
                          Foreground="#E5E7EB"
                          VerticalAlignment="Center"/>
            </Grid>
        </ScrollViewer>

        <DockPanel Grid.Row="2" Margin="0,16,0,0">
            <TextBlock x:Name="SettingsPathText"
                       DockPanel.Dock="Left"
                       Foreground="#6B7280"
                       FontSize="11"
                       VerticalAlignment="Center"/>
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="CancelButton" Content="Cancel" Width="90" Height="32" Margin="0,0,10,0"/>
                <Button x:Name="SaveButton" Content="Save" Width="90" Height="32"/>
            </StackPanel>
        </DockPanel>
    </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$settingsXaml)
    $settingsWindow = [Windows.Markup.XamlReader]::Load($reader)
    $settingsWindow.Owner = $window

    $sw = @{}
    @(
        "ProfileBox", "ThemeBox", "MaxLineBox", "IndentBox", "KeywordBox",
        "CommaBox", "SelectColumnsBox", "JoinBox", "WhereBox", "CaseBox",
        "CommentBoundaryBox", "CancelButton", "SaveButton", "SettingsPathText"
    ) | ForEach-Object {
        $sw[$_] = $settingsWindow.FindName($_)
    }

    Select-ComboValue $sw.ProfileBox ([string]$script:Settings.profile)
    Select-ComboValue $sw.ThemeBox ([string]$script:Settings.theme)
    Select-ComboValue $sw.MaxLineBox ([string]$script:Settings.maxLineLength)
    Select-ComboValue $sw.IndentBox ([string]$script:Settings.indentSize)
    Select-ComboValue $sw.KeywordBox ([string]$script:Settings.keywordCasing)
    Select-ComboValue $sw.CommaBox ([string]$script:Settings.commaStyle)
    Select-ComboValue $sw.SelectColumnsBox ([string]$script:Settings.selectColumns)
    Select-ComboValue $sw.JoinBox ([string]$script:Settings.joinAlignment)
    Select-ComboValue $sw.WhereBox ([string]$script:Settings.whereAlignment)
    Select-ComboValue $sw.CaseBox ([string]$script:Settings.caseStyle)

    $sw.CommentBoundaryBox.IsChecked = [bool]$script:Settings.preserveCommentLineBoundaries
    $sw.SettingsPathText.Text = $script:SettingsPath

    $sw.CancelButton.Add_Click({
        $settingsWindow.DialogResult = $false
        $settingsWindow.Close()
    })

    $sw.SaveButton.Add_Click({
        $script:Settings.profile = [string]$sw.ProfileBox.SelectedItem.Content
        $script:Settings.theme = [string]$sw.ThemeBox.SelectedItem.Content
        $script:Settings.maxLineLength = [int]$sw.MaxLineBox.SelectedItem.Content
        $script:Settings.indentSize = [int]$sw.IndentBox.SelectedItem.Content
        $script:Settings.keywordCasing = [string]$sw.KeywordBox.SelectedItem.Content
        $script:Settings.commaStyle = [string]$sw.CommaBox.SelectedItem.Content
        $script:Settings.selectColumns = [string]$sw.SelectColumnsBox.SelectedItem.Content
        $script:Settings.joinAlignment = [string]$sw.JoinBox.SelectedItem.Content
        $script:Settings.whereAlignment = [string]$sw.WhereBox.SelectedItem.Content
        $script:Settings.caseStyle = [string]$sw.CaseBox.SelectedItem.Content
        $script:Settings.preserveCommentLineBoundaries = [bool]$sw.CommentBoundaryBox.IsChecked

        Save-Settings
        Set-Theme -Dark ($script:Settings.theme -eq "Dark")
        Set-Status "Settings saved. Formatting options are stored but not applied yet."

        $settingsWindow.DialogResult = $true
        $settingsWindow.Close()
    })

    return $settingsWindow
}

$ui.OpenButton.Add_Click({
        try {
            $dialog = New-Object Microsoft.Win32.OpenFileDialog
            $dialog.Filter = "SQL files (*.sql)|*.sql|All files (*.*)|*.*"
            $dialog.Title = "Open SQL file"

            if ($dialog.ShowDialog() -eq $true) {
                $script:CurrentFilePath = $dialog.FileName
                $ui.InputBox.Text = Get-Content -Path $script:CurrentFilePath -Raw
                $ui.OutputBox.Clear()
                Set-Status "Opened: $script:CurrentFilePath"
            }
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Open failed", "OK", "Error") | Out-Null
            Set-Status "Open failed."
        }
    })

$ui.FormatButton.Add_Click({
        try {
            if ([string]::IsNullOrWhiteSpace($ui.InputBox.Text)) {
                Set-Status "Nothing to format."
                return
            }

            Set-Status "Formatting..."
            $window.Cursor = [System.Windows.Input.Cursors]::Wait
            $window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background)

            $ui.OutputBox.Text = Invoke-SqlFormatter -Sql $ui.InputBox.Text
            Set-Status "Formatted successfully."
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Format failed", "OK", "Error") | Out-Null
            Set-Status "Format failed."
        }
        finally {
            $window.Cursor = $null
        }
    })

$ui.CopyButton.Add_Click({
        try {
            if ([string]::IsNullOrWhiteSpace($ui.OutputBox.Text)) {
                Set-Status "No output to copy."
                return
            }

            [System.Windows.Clipboard]::SetText($ui.OutputBox.Text)
            Set-Status "Output copied."
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Copy failed", "OK", "Error") | Out-Null
            Set-Status "Copy failed."
        }
    })

$ui.SaveButton.Add_Click({
        try {
            if ([string]::IsNullOrWhiteSpace($ui.OutputBox.Text)) {
                Set-Status "No output to save."
                return
            }

            $dialog = New-Object Microsoft.Win32.SaveFileDialog
            $dialog.Filter = "SQL files (*.sql)|*.sql|All files (*.*)|*.*"
            $dialog.Title = "Save formatted SQL"

            if ($script:CurrentFilePath) {
                $folder = Split-Path -Parent $script:CurrentFilePath
                $name = [System.IO.Path]::GetFileNameWithoutExtension($script:CurrentFilePath)
                $dialog.InitialDirectory = $folder
                $dialog.FileName = "$name.formatted.sql"
            }
            else {
                $dialog.FileName = "formatted.sql"
            }

            if ($dialog.ShowDialog() -eq $true) {
                Set-Content -Path $dialog.FileName -Value $ui.OutputBox.Text -Encoding UTF8 -NoNewline
                Set-Status "Saved: $($dialog.FileName)"
            }
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Save failed", "OK", "Error") | Out-Null
            Set-Status "Save failed."
        }
    })

$ui.ReplaceButton.Add_Click({
        try {
            if (-not $script:CurrentFilePath) {
                Set-Status "No opened file to replace."
                return
            }

            if ([string]::IsNullOrWhiteSpace($ui.OutputBox.Text)) {
                Set-Status "No output to write."
                return
            }

            $answer = [System.Windows.MessageBox]::Show(
                "Replace this file with the formatted output?`n`n$script:CurrentFilePath",
                "Confirm replace",
                "YesNo",
                "Warning"
            )

            if ($answer -eq "Yes") {
                Set-Content -Path $script:CurrentFilePath -Value $ui.OutputBox.Text -Encoding UTF8 -NoNewline
                $ui.InputBox.Text = $ui.OutputBox.Text
                Set-Status "Replaced file: $script:CurrentFilePath"
            }
        }
        catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Replace failed", "OK", "Error") | Out-Null
            Set-Status "Replace failed."
        }
    })

$ui.ClearButton.Add_Click({
        $ui.InputBox.Clear()
        $ui.OutputBox.Clear()
        $script:CurrentFilePath = $null
        Set-Status "Cleared."
    })

$ui.ThemeButton.Add_Click({
        Set-Theme -Dark (-not $script:IsDarkTheme)
    })

$ui.SettingsButton.Add_Click({
    $settingsWindow = New-SettingsWindow
    [void]$settingsWindow.ShowDialog()
})

$ui.AboutButton.Add_Click({
        [System.Windows.MessageBox]::Show(
            "SQLFMT GUI`n`nWrapper around:`n$script:FormatterPath`n`nNo formatter logic lives in this GUI.",
            "About SQLFMT",
            "OK",
            "Information"
        ) | Out-Null
    })

[void]$window.ShowDialog()

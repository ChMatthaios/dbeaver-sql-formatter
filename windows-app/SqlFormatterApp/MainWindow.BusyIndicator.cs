using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace SqlFormatterApp;

public partial class MainWindow
{
    private Grid? _busyOverlay;
    private RotateTransform? _busySpinnerRotation;
    private DependencyPropertyDescriptor? _formatButtonEnabledDescriptor;

    protected override void OnContentRendered(EventArgs e)
    {
        base.OnContentRendered(e);

        if (_busyOverlay is not null)
        {
            return;
        }

        CreateBusyOverlay();

        _formatButtonEnabledDescriptor = DependencyPropertyDescriptor.FromProperty(
            UIElement.IsEnabledProperty,
            typeof(Button));

        _formatButtonEnabledDescriptor?.AddValueChanged(FormatButton, FormatButtonEnabledChanged);
        UpdateBusyIndicator();
    }

    protected override void OnClosed(EventArgs e)
    {
        if (_formatButtonEnabledDescriptor is not null)
        {
            _formatButtonEnabledDescriptor.RemoveValueChanged(FormatButton, FormatButtonEnabledChanged);
            _formatButtonEnabledDescriptor = null;
        }

        base.OnClosed(e);
    }

    private void FormatButtonEnabledChanged(object? sender, EventArgs e)
    {
        UpdateBusyIndicator();
    }

    private void UpdateBusyIndicator()
    {
        if (_busyOverlay is null)
        {
            return;
        }

        var busy = !FormatButton.IsEnabled;
        _busyOverlay.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;

        if (_busySpinnerRotation is null)
        {
            return;
        }

        if (busy)
        {
            var animation = new DoubleAnimation
            {
                From = 0,
                To = 360,
                Duration = TimeSpan.FromMilliseconds(850),
                RepeatBehavior = RepeatBehavior.Forever
            };

            _busySpinnerRotation.BeginAnimation(RotateTransform.AngleProperty, animation);
        }
        else
        {
            _busySpinnerRotation.BeginAnimation(RotateTransform.AngleProperty, null);
            _busySpinnerRotation.Angle = 0;
        }
    }

    private void CreateBusyOverlay()
    {
        if (Content is not Grid root)
        {
            return;
        }

        var overlay = new Grid
        {
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = true,
            Background = new SolidColorBrush(Color.FromArgb(62, 20, 24, 31))
        };
        Grid.SetRow(overlay, 1);
        Panel.SetZIndex(overlay, 1000);

        var card = new Border
        {
            Width = 300,
            MinHeight = 116,
            Padding = new Thickness(22, 18, 22, 18),
            CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        card.SetResourceReference(Border.BackgroundProperty, "SurfaceBrush");
        card.SetResourceReference(Border.BorderBrushProperty, "BorderBrush");

        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center
        };

        _busySpinnerRotation = new RotateTransform();

        var spinner = new Ellipse
        {
            Width = 38,
            Height = 38,
            StrokeThickness = 4,
            StrokeDashArray = new DoubleCollection { 1.3, 1.8 },
            StrokeDashCap = PenLineCap.Round,
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = _busySpinnerRotation,
            Margin = new Thickness(0, 0, 16, 0)
        };
        spinner.SetResourceReference(Shape.StrokeProperty, "AccentBrush");

        var labels = new StackPanel
        {
            VerticalAlignment = VerticalAlignment.Center
        };

        var title = new TextBlock
        {
            Text = "Formatting…",
            FontSize = 15,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 4)
        };
        title.SetResourceReference(TextBlock.ForegroundProperty, "TextPrimaryBrush");

        var subtitle = new TextBlock
        {
            Text = "Applying dialect and beautifier rules",
            FontSize = 12
        };
        subtitle.SetResourceReference(TextBlock.ForegroundProperty, "TextSecondaryBrush");

        labels.Children.Add(title);
        labels.Children.Add(subtitle);
        content.Children.Add(spinner);
        content.Children.Add(labels);
        card.Child = content;
        overlay.Children.Add(card);
        root.Children.Add(overlay);

        _busyOverlay = overlay;
    }
}

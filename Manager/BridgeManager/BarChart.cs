namespace BridgeManager;

/// <summary>
/// One bar series, drawn by hand. WinForms ships no chart that follows an
/// application palette or a right-to-left layout, and a charting package for
/// a single horizontal series is a dependency with a maintenance tail. Rows
/// arrive ready (label, value line, 0..1 fraction); all this does is paint.
///
/// Colours are read live from <see cref="Theme"/> on every paint, so a theme
/// switch only needs an Invalidate.
/// </summary>
internal sealed class BarChart : Control
{
    internal sealed record Bar(string Label, string Value, double Fraction);

    private IReadOnlyList<Bar> _bars = Array.Empty<Bar>();

    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public string EmptyText { get; set; } = "لا بيانات بعد.";

    private const int RowHeight = 56;
    private const int BarHeight = 10;
    private const int Pad = 14;

    public BarChart()
    {
        DoubleBuffered = true;
        ResizeRedraw = true;
        RightToLeft = RightToLeft.Yes;
        BackColor = Theme.Surface;
        Font = Theme.Ui;
        AccessibleName = "رسم أعمدة";
    }

    public void SetData(IReadOnlyList<Bar> bars)
    {
        _bars = bars;
        AccessibleDescription = bars.Count == 0 ? EmptyText : $"{bars.Count} أعمدة";
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;

        if (_bars.Count == 0)
        {
            using var empty = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            using var brush = new SolidBrush(Theme.TextMuted);
            g.DrawString(EmptyText, Theme.Ui, brush, ClientRectangle, empty);
            return;
        }

        using var labelBrush = new SolidBrush(Theme.Text);
        using var valueBrush = new SolidBrush(Theme.TextMuted);
        using var trackBrush = new SolidBrush(Theme.SurfaceAlt);
        using var fillBrush = new SolidBrush(Theme.Accent);
        using var near = new StringFormat { Alignment = StringAlignment.Near, LineAlignment = StringAlignment.Near, Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap };
        using var far = new StringFormat { Alignment = StringAlignment.Far, LineAlignment = StringAlignment.Near, Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap };

        // RightToLeft.Yes mirrors Near/Far for us: Near is the leading (right)
        // edge. Label and value get their own thirds of the line, so a long
        // template name meets "357 مرة" with an ellipsis, not a collision.
        var y = Pad;
        var labelWidth = (Width - Pad * 2) * 0.62f;
        foreach (var bar in _bars)
        {
            var labelRect = new RectangleF(Width - Pad - labelWidth, y, labelWidth, 22);
            var valueRect = new RectangleF(Pad, y, Width - Pad * 2 - labelWidth - 8, 22);
            g.DrawString(bar.Label, Theme.UiBold, labelBrush, labelRect, near);
            g.DrawString(bar.Value, Theme.UiSmall, valueBrush, valueRect, far);

            var track = new RectangleF(Pad, y + 26, Width - Pad * 2, BarHeight);
            g.FillRectangle(trackBrush, track);
            var fillWidth = (float)(track.Width * Math.Clamp(bar.Fraction, 0, 1));
            if (fillWidth > 0)
            {
                // Fill from the leading edge: the longest bar starts where the
                // eye starts, in either direction.
                var fill = RightToLeft == RightToLeft.Yes
                    ? new RectangleF(track.Right - fillWidth, track.Y, fillWidth, track.Height)
                    : new RectangleF(track.X, track.Y, fillWidth, track.Height);
                g.FillRectangle(fillBrush, fill);
            }
            y += RowHeight;
        }
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        Invalidate();
    }
}

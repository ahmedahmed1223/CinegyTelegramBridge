using System.Runtime.InteropServices;

namespace BridgeManager;

/// <summary>
/// One palette and one set of control builders for both windows, in two modes.
///
/// Light is the default: this app is opened during the day by people who also
/// have Explorer, Notepad and the Cinegy client on screen, and a lone black
/// window among them reads as a different application every time. Dark is a
/// switch rather than a decision made for the operator - the same desk at
/// night, with a programme monitor next to it, is exactly where dark earns
/// its place.
///
/// The state colours are load-bearing rather than decorative: green, red and
/// amber mean running, stopped and in-between, they appear nowhere else, and
/// both palettes keep them legible against their own background so the header
/// can be read from across the room without focusing on the text.
/// </summary>
internal static class Theme
{
    /// <summary>False is light, and light is the default.</summary>
    public static bool IsDark { get; private set; }

    public static void SetMode(bool dark) => IsDark = dark;

    // ---- surfaces ---------------------------------------------------------
    public static Color Background => IsDark ? Color.FromArgb(24, 24, 28) : Color.FromArgb(245, 246, 248);
    public static Color Surface => IsDark ? Color.FromArgb(36, 36, 42) : Color.FromArgb(255, 255, 255);
    public static Color SurfaceAlt => IsDark ? Color.FromArgb(48, 48, 56) : Color.FromArgb(236, 238, 242);
    public static Color Border => IsDark ? Color.FromArgb(64, 64, 74) : Color.FromArgb(210, 214, 222);
    public static Color Text => IsDark ? Color.FromArgb(233, 233, 238) : Color.FromArgb(27, 29, 33);
    public static Color TextMuted => IsDark ? Color.FromArgb(148, 148, 160) : Color.FromArgb(103, 110, 122);

    // ---- the three bridge states, reserved for exactly that ---------------
    // Darker in light mode: the greens and ambers that read well on near-black
    // fall below usable contrast on white.
    public static Color Running => IsDark ? Color.FromArgb(46, 170, 108) : Color.FromArgb(21, 128, 78);
    public static Color Stopped => IsDark ? Color.FromArgb(222, 82, 74) : Color.FromArgb(192, 44, 36);
    public static Color Pending => IsDark ? Color.FromArgb(226, 162, 58) : Color.FromArgb(166, 110, 12);
    public static Color Accent => IsDark ? Color.FromArgb(72, 150, 245) : Color.FromArgb(28, 105, 216);

    // ---- log line colours, tuned against each mode's own pane -------------
    public static Color LogBackground => IsDark ? Color.FromArgb(24, 24, 28) : Color.FromArgb(252, 252, 253);
    public static Color LogNormal => IsDark ? Color.FromArgb(206, 206, 214) : Color.FromArgb(36, 38, 43);
    public static Color LogError => IsDark ? Color.FromArgb(255, 122, 116) : Color.FromArgb(185, 38, 30);
    public static Color LogWarning => IsDark ? Color.FromArgb(240, 186, 88) : Color.FromArgb(148, 98, 8);
    public static Color LogDebug => IsDark ? Color.FromArgb(126, 126, 138) : Color.FromArgb(132, 138, 148);
    public static Color LogManager => IsDark ? Color.FromArgb(112, 178, 255) : Color.FromArgb(28, 105, 216);
    public static Color LogTimestamp => IsDark ? Color.FromArgb(155, 155, 170) : Color.FromArgb(92, 98, 110);
    public static Color LogLevel => IsDark ? Color.FromArgb(183, 149, 255) : Color.FromArgb(103, 63, 178);
    public static Color LogOperation => IsDark ? Color.FromArgb(114, 207, 255) : Color.FromArgb(0, 104, 160);
    public static Color LogField => IsDark ? Color.FromArgb(208, 208, 220) : Color.FromArgb(66, 70, 78);

    // ---- chip fills, which cannot simply be the accent in both modes ------
    // A dark-blue fill under dark text is unreadable on a light form, and a
    // pale fill under light text is unreadable on a dark one.
    public static Color ChipOnFill => IsDark ? Darken(Accent, 0.45) : Lighten(Accent, 0.86);
    public static Color ChipOnFore => IsDark ? Text : Darken(Accent, 0.25);
    public static Color ChipOnHover => IsDark ? Darken(Accent, 0.32) : Lighten(Accent, 0.76);

    // Cached: a property that news up a Font on every read hands out hundreds
    // of GDI handles over a long session.
    public static readonly Font Ui = new("Segoe UI", 9.75f);
    public static readonly Font UiBold = new("Segoe UI Semibold", 9.75f);
    public static readonly Font UiSmall = new("Segoe UI", 8.5f);
    public static readonly Font Title = new("Segoe UI Semibold", 16f);
    public static readonly Font SectionHeading = new("Segoe UI Semibold", 10.5f);
    public static readonly Font Mono = new("Segoe UI", 10f);

    /// <summary>
    /// Matches the OS title bar to the window. Without it Windows draws a white
    /// caption above a near-black form, which looks like a bug rather than a
    /// choice. Silently does nothing where the attribute is unknown.
    /// </summary>
    public static void ApplyTitleBar(IntPtr handle)
    {
        try
        {
            const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
            var enabled = IsDark ? 1 : 0;
            DwmSetWindowAttribute(handle, DWMWA_USE_IMMERSIVE_DARK_MODE, ref enabled, sizeof(int));
        }
        catch (DllNotFoundException) { /* no dwmapi on this shell */ }
        catch (EntryPointNotFoundException) { /* attribute unknown on this build */ }
    }

    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    /// <summary>
    /// Re-applies the current palette to a whole control tree.
    ///
    /// Every control the factories below build carries its own restyle
    /// delegate in Tag, because a button's colours depend on which role it was
    /// given (start, stop, quiet) and that cannot be recovered by looking at
    /// the control afterwards. Anything without one is coloured by type.
    /// </summary>
    public static void Apply(Control root)
    {
        foreach (Control child in root.Controls) Apply(child);

        if (root.Tag is Action restyle) { restyle(); return; }

        switch (root)
        {
            case TextBox box:
                box.BackColor = SurfaceAlt;
                box.ForeColor = Text;
                break;
            case NumericUpDown spin:
                spin.BackColor = SurfaceAlt;
                spin.ForeColor = Text;
                break;
            case ContextMenuStrip menu:
                menu.BackColor = Surface;
                menu.ForeColor = Text;
                break;
        }
    }

    /// <summary>
    /// A solid button for the actions that change what the bridge is doing.
    /// Disabled state is styled explicitly: a flat button left to Windows'
    /// default disabled rendering keeps its full-strength background and only
    /// greys the text, so "Stop" looked live while it was inert.
    /// </summary>
    public static Button PrimaryButton(string text, Func<Color> fill)
    {
        var button = BaseButton(text);
        button.Font = UiBold;

        void Apply()
        {
            var colour = fill();
            button.BackColor = button.Enabled ? colour : SurfaceAlt;
            button.ForeColor = button.Enabled ? Color.White : TextMuted;
            button.FlatAppearance.BorderSize = 0;
            button.FlatAppearance.MouseOverBackColor = Lighten(colour, 0.14);
            button.FlatAppearance.MouseDownBackColor = Darken(colour, 0.16);
        }

        button.Tag = (Action)Apply;
        button.EnabledChanged += (_, _) => Apply();
        Apply();
        return button;
    }

    /// <summary>
    /// A quiet button for everything that only opens something or tidies the
    /// view. Giving these the same weight as Start/Stop was the old toolbar's
    /// main problem: eleven controls, all shouting equally.
    /// </summary>
    public static Button QuietButton(string text)
    {
        var button = BaseButton(text);
        button.Font = Ui;

        void Apply()
        {
            button.BackColor = button.Enabled ? SurfaceAlt : Surface;
            button.ForeColor = button.Enabled ? Text : TextMuted;
            button.FlatAppearance.BorderSize = 1;
            button.FlatAppearance.BorderColor = Border;
            button.FlatAppearance.MouseOverBackColor = IsDark ? Lighten(SurfaceAlt, 0.10) : Darken(SurfaceAlt, 0.05);
            button.FlatAppearance.MouseDownBackColor = IsDark ? Lighten(SurfaceAlt, 0.18) : Darken(SurfaceAlt, 0.11);
        }

        button.Tag = (Action)Apply;
        button.EnabledChanged += (_, _) => Apply();
        Apply();
        return button;
    }

    private static Button BaseButton(string text) => new()
    {
        Text = text,
        AutoSize = false,
        Height = 36,
        FlatStyle = FlatStyle.Flat,
        Cursor = Cursors.Hand,
        TextAlign = ContentAlignment.MiddleCenter,
        Margin = new Padding(0, 0, 8, 0),
        UseVisualStyleBackColor = false
    };

    /// <summary>
    /// A pill that is filled when on and outlined when off.
    ///
    /// Not a plain checkbox: a checkbox glyph on a dark surface is drawn dark
    /// on dark, and a screenshot of the first dark build showed five options
    /// whose state genuinely could not be read. State here is carried by fill
    /// and border colour, which survive both palettes, any DPI, and a glance
    /// from the other side of the desk. Keep the label short - the full
    /// sentence belongs in the tooltip.
    /// </summary>
    public static CheckBox ToggleChip(string text, string? tooltipText = null, ToolTip? tips = null)
    {
        var box = new CheckBox
        {
            // Padded with spaces because the Padding property is unusable here
            // (see MinimumSize below); AutoSize then measures the padding as
            // part of the label and the chip gets its horizontal breathing
            // room for free.
            Text = "  " + text + "  ",
            AutoSize = true,
            Appearance = Appearance.Button,
            FlatStyle = FlatStyle.Flat,
            TextAlign = ContentAlignment.MiddleCenter,
            Font = Ui,
            Cursor = Cursors.Hand,
            // No Padding, and the breathing room comes from MinimumSize plus
            // padded text instead: an AutoSize CheckBox drawn as a button
            // subtracts Padding from a text rectangle that AutoSize had
            // already sized to the text alone, leaving nothing to draw into -
            // the first build of these chips rendered as coloured rectangles
            // with no labels at all, in both palettes.
            MinimumSize = new Size(0, 34),
            Margin = new Padding(0, 0, 8, 4),
            UseVisualStyleBackColor = false
        };
        box.AccessibleName = text;
        box.AccessibleRole = AccessibleRole.CheckButton;
        box.FlatAppearance.BorderSize = 1;

        void Apply()
        {
            var on = box.Checked;
            box.Text = on ? "  ✓ " + text + "  " : "  " + text + "  ";
            box.BackColor = on ? ChipOnFill : Surface;
            box.ForeColor = on ? ChipOnFore : TextMuted;
            box.FlatAppearance.BorderColor = on ? Accent : Border;
            box.FlatAppearance.CheckedBackColor = ChipOnFill;
            box.FlatAppearance.MouseOverBackColor = on ? ChipOnHover : SurfaceAlt;
        }

        box.Tag = (Action)Apply;
        box.CheckedChanged += (_, _) => Apply();
        Apply();
        if (tooltipText is not null) tips?.SetToolTip(box, tooltipText);
        return box;
    }

    public static TextBox Input(int width)
    {
        var box = new TextBox
        {
            Width = width,
            Font = Ui,
            BorderStyle = BorderStyle.FixedSingle,
            Margin = new Padding(0, 2, 0, 2)
        };
        void Apply() { box.BackColor = SurfaceAlt; box.ForeColor = Text; }
        box.Tag = (Action)Apply;
        Apply();
        return box;
    }

    public static Label Caption(string text) => Styled(new Label
    {
        Text = text,
        AutoSize = true,
        Font = Ui,
        Margin = new Padding(0, 8, 10, 0)
    }, () => Text);

    public static Label Hint(string text) => Styled(new Label
    {
        Text = text,
        AutoSize = true,
        Font = UiSmall,
        Margin = new Padding(0, 0, 0, 10)
    }, () => TextMuted);

    public static Label Heading(string text) => Styled(new Label
    {
        Text = text,
        AutoSize = true,
        Font = SectionHeading,
        Margin = new Padding(0, 14, 0, 8)
    }, () => Accent);

    private static Label Styled(Label label, Func<Color> fore)
    {
        void Apply() { label.ForeColor = fore(); label.BackColor = Color.Transparent; }
        label.Tag = (Action)Apply;
        Apply();
        return label;
    }

    public static Color Lighten(Color c, double amount) => Color.FromArgb(
        c.A,
        (int)Math.Min(255, c.R + (255 - c.R) * amount),
        (int)Math.Min(255, c.G + (255 - c.G) * amount),
        (int)Math.Min(255, c.B + (255 - c.B) * amount));

    public static Color Darken(Color c, double amount) => Color.FromArgb(
        c.A,
        (int)Math.Max(0, c.R * (1 - amount)),
        (int)Math.Max(0, c.G * (1 - amount)),
        (int)Math.Max(0, c.B * (1 - amount)));
}

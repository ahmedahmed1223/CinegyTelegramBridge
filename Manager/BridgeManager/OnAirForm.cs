using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BridgeManager;

/// <summary>
/// "What is on air" - a read-only window over the bridge's own on-air record.
///
/// The bridge already writes logs/onair.json on every change, so this asks
/// nothing of it and touches nothing on air: no buttons here SHOW or HIDE
/// anything. Friendly names come from templates.json, layer nicknames from
/// the LayerNames setting ("7=عاجل;8=شريط الأخبار"), and publisher names
/// from logs/user-aliases.json - every one of them best-effort, falling back
/// to the raw id or key, because a display nicety must never blank a row.
///
/// Refreshes itself every five seconds while open; the timer dies with the
/// dialog.
/// </summary>
public sealed class OnAirForm : Form
{
    internal sealed record OnAirRow(int Layer, string Key, string AirCopy, DateTime? AtLocal, long UserId, string Source);

    private readonly string _bridgeRoot;
    private readonly ListView _list;
    private readonly Label _emptyLabel;
    private readonly Label _readStatus;
    private DateTime? _lastRead;
    private readonly System.Windows.Forms.Timer _refreshTimer;

    public OnAirForm(string bridgeRoot)
    {
        _bridgeRoot = bridgeRoot;

        Text = "ماذا على الهواء";
        Width = 800;
        Height = 520;
        MinimumSize = new Size(620, 380);
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.Sizable;
        MaximizeBox = true;
        MinimizeBox = false;
        BackColor = Theme.Background;
        ForeColor = Theme.Text;
        Font = Theme.Ui;
        RightToLeft = RightToLeft.Yes;
        RightToLeftLayout = true;

        var header = new Panel { Dock = DockStyle.Top, Height = 62, BackColor = Theme.Surface, Padding = new Padding(18, 10, 18, 10) };
        var headerHint = new Label { Dock = DockStyle.Top, Height = 18, Text = "يُقرأ من سجل الجسر كل 5 ثوانٍ — عرض فقط، ولا زرّ هواء هنا.", Font = Theme.UiSmall, ForeColor = Theme.TextMuted };
        var headerTitle = new Label { Dock = DockStyle.Top, Height = 22, Text = "📡 على الهواء الآن", Font = Theme.SectionHeading, ForeColor = Theme.Text };
        header.Controls.Add(headerHint);
        header.Controls.Add(headerTitle);

        _list = new ListView
        {
            Dock = DockStyle.Fill,
            View = View.Details,
            FullRowSelect = true,
            HideSelection = false,
            BackColor = Theme.Surface,
            ForeColor = Theme.Text,
            Font = Theme.Ui,
            BorderStyle = BorderStyle.FixedSingle,
            Margin = new Padding(18, 8, 18, 8)
        };
        _list.Columns.Add("الطبقة", 120);
        _list.Columns.Add("القالب", 150);
        _list.Columns.Add("النص", 200);
        _list.Columns.Add("منذ", 110);
        _list.Columns.Add("الناشر", 130);
        _list.Columns.Add("المصدر", 80);

        _emptyLabel = new Label
        {
            Dock = DockStyle.Fill,
            Text = "لا توجد مشاهد مسجلة لدى الجسر.",
            TextAlign = ContentAlignment.MiddleCenter,
            Font = Theme.Ui,
            ForeColor = Theme.TextMuted,
            Visible = false
        };

        var buttons = new Panel { Dock = DockStyle.Bottom, Height = 60, BackColor = Theme.Surface, Padding = new Padding(18, 12, 18, 12) };
        var buttonFlow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, WrapContents = false };
        var refreshButton = Theme.QuietButton("🔄 تحديث");
        refreshButton.Width = 120;
        refreshButton.Click += (_, _) => Reload();
        var closeButton = Theme.QuietButton("إغلاق");
        closeButton.Width = 100;
        closeButton.DialogResult = DialogResult.Cancel;
        buttonFlow.Controls.AddRange(new Control[] { refreshButton, closeButton });
        buttons.Controls.Add(buttonFlow);

        _readStatus = new Label { Dock = DockStyle.Bottom, Height = 44, Padding = new Padding(12, 4, 12, 4),
            Text = "لم تُقرأ الحالة بعد.", Font = Theme.UiSmall, ForeColor = Theme.Pending };
        Controls.Add(_list);
        Controls.Add(_emptyLabel);
        Controls.Add(_readStatus);
        Controls.Add(buttons);
        Controls.Add(header);

        CancelButton = closeButton;

        _refreshTimer = new System.Windows.Forms.Timer { Interval = 5000 };
        _refreshTimer.Tick += (_, _) => Reload();
        Load += (_, _) => { Reload(); _refreshTimer.Start(); };
        FormClosed += (_, _) => { _refreshTimer.Stop(); _refreshTimer.Dispose(); };
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.ApplyTitleBar(Handle);
    }

    private void Reload()
    {
        try
        {
            var rows = ParseOnAirRows(ReadSharedFile(Path.Combine(_bridgeRoot, "logs", "onair.json")));
            var names = ReadTemplateNames(ReadSharedFile(Path.Combine(_bridgeRoot, "templates.json")));
            var layers = ReadLayerNames(ReadBridgeSetting("LayerNames"));
            var aliases = ReadAliases(ReadSharedFile(Path.Combine(_bridgeRoot, "logs", "user-aliases.json")));

            _list.BeginUpdate();
            try
            {
            _list.Items.Clear();
            foreach (var row in rows.OrderBy(r => r.Layer))
            {
                var layerName = layers.TryGetValue(row.Layer, out var nick) ? $" · {nick}" : "";
                var template = names.TryGetValue(row.Key, out var friendly) ? friendly : row.Key;
                var since = row.AtLocal is null ? "—" : "منذ " + MainForm.FormatSpan(DateTime.Now - row.AtLocal.Value);
                var item = new ListViewItem($"الطبقة {row.Layer}{layerName}");
                item.SubItems.Add(template);
                item.SubItems.Add(row.AirCopy);
                item.SubItems.Add(since);
                item.SubItems.Add(ResolveActor(row.UserId, aliases));
                item.SubItems.Add(string.Equals(row.Source, "bridge", StringComparison.OrdinalIgnoreCase) ? "الجسر" : "خارجي");
                _list.Items.Add(item);
            }
            }
            finally { _list.EndUpdate(); }
            _lastRead = DateTime.Now;
            var heartbeat = MainForm.ParseLiveness(ReadSharedFile(Path.Combine(_bridgeRoot, "logs", "bridge.liveness"))).Stamp;
            _readStatus.Text = ReadStatusText(true, _lastRead, heartbeat, DateTime.UtcNow);
            _readStatus.ForeColor = IsHeartbeatFresh(heartbeat, DateTime.UtcNow) ? Theme.TextMuted : Theme.Pending;
            _emptyLabel.Visible = rows.Count == 0;
            _list.Visible = rows.Count > 0;
        }
        catch
        {
            _emptyLabel.Visible = false;
            _list.Visible = true;
            _readStatus.Text = ReadStatusText(false, _lastRead, null, DateTime.UtcNow);
            _readStatus.ForeColor = Theme.Pending;
        }
    }

    private string? ReadBridgeSetting(string name)
    {
        try
        {
            var root = JsonNode.Parse(ReadSharedFile(Path.Combine(_bridgeRoot, "config.json")) ?? "{}");
            return (string?)root?["Settings"]?[name];
        }
        catch { return null; }
    }

    private static string? ReadSharedFile(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd();
        }
        catch { return null; }
    }

    /// <summary>
    /// A number that may arrive as a JSON number or a JSON string: onair.json
    /// writes layers and ids as numbers, a hand-edited file as strings, and
    /// casting a number node straight to string throws instead of converting
    /// (which once blanked this whole window from a single cast).
    /// </summary>
    internal static bool TryReadInt64(JsonNode? node, out long value)
    {
        value = 0;
        try
        {
            if (node is JsonValue v && v.TryGetValue<long>(out value)) return true;
            return long.TryParse((string?)node, NumberStyles.Integer, CultureInfo.InvariantCulture, out value);
        }
        catch { value = 0; return false; }
    }

    internal static bool TryReadInt32(JsonNode? node, out int value)
    {
        var ok = TryReadInt64(node, out var wide);
        value = ok && wide >= int.MinValue && wide <= int.MaxValue ? (int)wide : 0;
        return ok && wide >= int.MinValue && wide <= int.MaxValue;
    }

    internal static bool IsHeartbeatFresh(DateTime? heartbeat, DateTime utcNow) =>
        heartbeat is DateTime stamp && utcNow - stamp.ToUniversalTime() >= TimeSpan.Zero && utcNow - stamp.ToUniversalTime() <= TimeSpan.FromMinutes(5);

    internal static string ReadStatusText(bool readSucceeded, DateTime? lastRead, DateTime? heartbeat, DateTime utcNow)
    {
        var stamp = lastRead is DateTime at ? $"آخر قراءة سليمة للسجل: {at:HH:mm:ss}." : "لا توجد قراءة سليمة بعد.";
        if (!readSucceeded) return "⚠ تعذّرت قراءة الحالة؛ المعروض إن وجد آخر سجل متاح. " + stamp;
        return IsHeartbeatFresh(heartbeat, utcNow)
            ? stamp + " المعروض من سجل الجسر، وليس فحصًا مباشرًا للخرج."
            : "⚠ نبضة الجسر قديمة أو غير متاحة؛ حالة الهواء غير مؤكدة. " + stamp;
    }

    /// <summary>Invalid state is unavailable, never evidence of an empty output.</summary>
    internal static List<OnAirRow> ParseOnAirRows(string? json)
    {
        var rows = new List<OnAirRow>();
        try
        {
            if (string.IsNullOrWhiteSpace(json)) throw new InvalidDataException("On-air state unavailable.");
            var root = JsonNode.Parse(json);
            if (root?["Scenes"] is not JsonArray scenes) throw new InvalidDataException("On-air scene list unavailable.");
            foreach (var scene in scenes)
            {
                if (scene is null || !TryReadInt32(scene["Layer"], out var layer))
                    throw new InvalidDataException("Invalid on-air scene.");
                var key = (string?)scene["Key"] ?? "";
                if (string.IsNullOrWhiteSpace(key)) throw new InvalidDataException("Invalid on-air scene.");
                TryReadInt64(scene["UserId"], out var userId);
                rows.Add(new OnAirRow(layer, key, (string?)scene["AirCopy"] ?? "", ParseOnAirStamp((string?)scene["At"]),
                    userId, (string?)scene["Source"] ?? ""));
            }
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or FormatException)
        {
            throw new InvalidDataException("On-air state unavailable.");
        }
        return rows;
    }

    /// <summary>
    /// The stamp the bridge writes ("09/11/2026 15:50:04" in its locale, or an
    /// 'o' round-trip in newer files). MM/dd first and never dd/MM: guessing
    /// the day-month order wrong moves a graphic by two months.
    /// </summary>
    internal static DateTime? ParseOnAirStamp(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var trimmed = text.Trim();
        if (DateTime.TryParseExact(trimmed, "MM/dd/yyyy HH:mm:ss", CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeLocal, out var exact))
            return exact;
        if (DateTime.TryParse(trimmed, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var round))
            return round.Kind == DateTimeKind.Unspecified
                ? DateTime.SpecifyKind(round, DateTimeKind.Local)
                : round;
        if (DateTime.TryParse(trimmed, out var local))
            return DateTime.SpecifyKind(local, DateTimeKind.Local);
        return null;
    }

    /// <summary>Template key to its description, for rows humans read.</summary>
    internal static Dictionary<string, string> ReadTemplateNames(string? json)
    {
        var names = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            var root = JsonNode.Parse(string.IsNullOrWhiteSpace(json) ? "{}" : json) as JsonObject;
            if (root is null) return names;
            foreach (var pair in root)
            {
                var description = (string?)pair.Value?["description"];
                names[pair.Key] = string.IsNullOrWhiteSpace(description) ? pair.Key : description;
            }
        }
        catch { /* torn registry - keys stand in for names */ }
        return names;
    }

    /// <summary>Parses the LayerNames setting ("7=عاجل;8=شريط الأخبار"), skipping junk entries.</summary>
    internal static Dictionary<int, string> ReadLayerNames(string? setting)
    {
        var layers = new Dictionary<int, string>();
        if (string.IsNullOrWhiteSpace(setting)) return layers;
        foreach (var pair in setting.Split(';'))
        {
            var cut = pair.IndexOf('=');
            if (cut <= 0) continue;
            if (!int.TryParse(pair[..cut].Trim(), out var layer)) continue;
            var name = pair[(cut + 1)..].Trim();
            if (name.Length > 0) layers[layer] = name;
        }
        return layers;
    }

    /// <summary>Publisher id to the alias an operator once set, for rows humans read.</summary>
    internal static Dictionary<string, string> ReadAliases(string? json)
    {
        var aliases = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            var root = JsonNode.Parse(string.IsNullOrWhiteSpace(json) ? "{}" : json) as JsonObject;
            if (root is null) return aliases;
            foreach (var pair in root)
            {
                var name = (string?)pair.Value;
                if (!string.IsNullOrWhiteSpace(name)) aliases[pair.Key] = name;
            }
        }
        catch { /* torn file - raw ids stand in */ }
        return aliases;
    }

    /// <summary>A publisher the operator recognises: alias when one was ever set, the raw id otherwise.</summary>
    internal static string ResolveActor(long userId, IDictionary<string, string> aliases) =>
        aliases.TryGetValue(userId.ToString(CultureInfo.InvariantCulture), out var alias) && alias.Length > 0
            ? alias
            : userId.ToString(CultureInfo.InvariantCulture);
}

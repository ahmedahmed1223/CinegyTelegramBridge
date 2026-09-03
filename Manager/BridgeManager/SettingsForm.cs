using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BridgeManager;

/// <summary>
/// Edits only the config.json fields that are NOT reachable from the bot's own
/// in-chat Settings screen (bot token, engine address, id whitelists) - see the
/// "_comment_settings" note in config.example.json: everything under "Settings"
/// is already editable live from Telegram, so this form does not duplicate it.
/// Unknown/untouched keys are preserved via JsonNode round-trip.
/// </summary>
public sealed class SettingsForm : Form
{
    private readonly string _configPath;
    private readonly string _bridgeRoot;
    private readonly TextBox _botToken = new() { Width = 420 };
    private readonly TextBox _airServer = new() { Width = 200 };
    private readonly NumericUpDown _airChannel = new() { Width = 100, Minimum = 0, Maximum = 999 };
    private readonly TextBox _allowedChatIds = new() { Width = 420 };
    private readonly TextBox _adminChatIds = new() { Width = 420 };
    private readonly TextBox _allowedUserIds = new() { Width = 420 };
    private readonly TextBox _adminUserIds = new() { Width = 420 };
    private readonly TextBox _ownerUserIds = new() { Width = 420 };

    public bool RestartRequested { get; private set; }

    public SettingsForm(string configPath, string bridgeRoot)
    {
        _configPath = configPath;
        _bridgeRoot = bridgeRoot;

        Text = "إعدادات الجسر (config.json)";
        Width = 620;
        Height = 480;
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;

        if (!File.Exists(_configPath) && File.Exists(Path.Combine(_bridgeRoot, "config.example.json")))
        {
            var offer = MessageBox.Show(this,
                "لا يوجد config.json بعد. إنشاؤه من config.example.json؟",
                "لا يوجد ملف إعدادات", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (offer == DialogResult.Yes)
                File.Copy(Path.Combine(_bridgeRoot, "config.example.json"), _configPath);
        }

        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Padding = new Padding(12), AutoSize = true };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        void Row(string label, Control control)
        {
            layout.RowCount++;
            layout.Controls.Add(new Label { Text = label, AutoSize = true, TextAlign = ContentAlignment.MiddleLeft, Anchor = AnchorStyles.Left, Margin = new Padding(0, 8, 8, 0) });
            layout.Controls.Add(control);
        }

        Row("رمز البوت (BotToken):", _botToken);
        Row("عنوان محرك Air Pro:", _airServer);
        Row("رقم القناة:", _airChannel);
        Row("Chat IDs مسموحة (فاصلة بينها):", _allowedChatIds);
        Row("Chat IDs إدارية:", _adminChatIds);
        Row("User IDs مسموحة:", _allowedUserIds);
        Row("User IDs إدارية:", _adminUserIds);
        Row("User IDs مالكة (Owner، اختياري):", _ownerUserIds);

        var note = new Label
        {
            Text = "باقي الإعدادات (كل ما تحت \"Settings\") تُعدَّل مباشرة من داخل البوت في تيليجرام.",
            AutoSize = true,
            ForeColor = Color.DimGray,
            Margin = new Padding(0, 12, 0, 0)
        };
        layout.RowCount++;
        layout.SetColumnSpan(note, 2);
        layout.Controls.Add(note);

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 44, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(8) };
        var saveButton = new Button { Text = "حفظ", Width = 90 };
        var saveRestartButton = new Button { Text = "حفظ وإعادة التشغيل", Width = 150 };
        var cancelButton = new Button { Text = "إلغاء", Width = 90, DialogResult = DialogResult.Cancel };
        var openFileButton = new Button { Text = "فتح الملف في المفكرة", Width = 160 };

        saveButton.Click += (_, _) => { if (Save()) DialogResult = DialogResult.OK; };
        saveRestartButton.Click += (_, _) => { if (Save()) { RestartRequested = true; DialogResult = DialogResult.OK; } };
        openFileButton.Click += (_, _) => Process.Start(new ProcessStartInfo("notepad.exe", $"\"{_configPath}\"") { UseShellExecute = true });

        buttons.Controls.AddRange(new Control[] { cancelButton, saveRestartButton, saveButton, openFileButton });

        var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
        scroll.Controls.Add(layout);

        Controls.Add(scroll);
        Controls.Add(buttons);
        AcceptButton = saveButton;
        CancelButton = cancelButton;

        Load += (_, _) => LoadValues();
    }

    private JsonNode LoadRoot()
    {
        if (!File.Exists(_configPath)) return new JsonObject();
        var json = File.ReadAllText(_configPath);
        return JsonNode.Parse(json) ?? new JsonObject();
    }

    private void LoadValues()
    {
        try
        {
            var root = LoadRoot();
            _botToken.Text = (string?)root["BotToken"] ?? "";
            _airServer.Text = (string?)root["AirServerAddress"] ?? "127.0.0.1";
            _airChannel.Value = Math.Clamp((int?)root["AirChannelNumber"] ?? 0, 0, 999);
            _allowedChatIds.Text = FormatIds(root["AllowedChatIds"]);
            _adminChatIds.Text = FormatIds(root["AdminChatIds"]);
            _allowedUserIds.Text = FormatIds(root["AllowedUserIds"]);
            _adminUserIds.Text = FormatIds(root["AdminUserIds"]);
            _ownerUserIds.Text = FormatIds(root["OwnerUserIds"]);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"تعذّرت قراءة config.json:\n{ex.Message}", "خطأ", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    internal static string FormatIds(JsonNode? array) =>
        array is JsonArray arr ? string.Join(", ", arr.Select(n => n?.ToString() ?? "")) : "";

    internal static JsonArray ParseIds(string text)
    {
        var arr = new JsonArray();
        foreach (var part in text.Split(new[] { ',', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            if (long.TryParse(part, out var id)) arr.Add(id);
        }
        return arr;
    }

    private bool Save()
    {
        if (string.IsNullOrWhiteSpace(_botToken.Text))
        {
            MessageBox.Show(this, "رمز البوت (BotToken) مطلوب.", "تحقّق", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
        try
        {
            var root = LoadRoot();
            root["BotToken"] = _botToken.Text.Trim();
            root["AirServerAddress"] = _airServer.Text.Trim();
            root["AirChannelNumber"] = (int)_airChannel.Value;
            root["AllowedChatIds"] = ParseIds(_allowedChatIds.Text);
            root["AdminChatIds"] = ParseIds(_adminChatIds.Text);
            root["AllowedUserIds"] = ParseIds(_allowedUserIds.Text);
            root["AdminUserIds"] = ParseIds(_adminUserIds.Text);
            root["OwnerUserIds"] = ParseIds(_ownerUserIds.Text);

            var json = root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(_configPath, json);
            return true;
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"تعذّر الحفظ:\n{ex.Message}", "خطأ", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
    }
}

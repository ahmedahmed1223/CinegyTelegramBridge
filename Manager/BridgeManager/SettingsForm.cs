using System.Diagnostics;
using System.Globalization;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BridgeManager;

/// <summary>
/// Edits only the config.json fields that are NOT reachable from the bot's own
/// in-chat Settings screen (bot token, engine address, account permissions) -
/// see the "_comment_settings" note in config.example.json: everything under
/// "Settings" is already editable live from Telegram, so this form does not
/// duplicate it. Unknown/untouched keys are preserved via JsonNode round-trip.
///
/// Accounts are one row per id, with that id's permissions ticked beside the
/// list - not five text boxes of comma-separated numbers, and not one row per
/// (id, permission) pair either.
///
/// The reason is that all five arrays share a single id space: Telegram gives
/// a private chat the same id as the person in it, so one operator normally
/// appears in AllowedChatIds *and* AllowedUserIds, and an admin in four arrays
/// at once. Spread across five text boxes that person was five separate
/// numbers to keep in sync by hand; listed per pair they were four rows saying
/// nearly the same thing. One row, five ticks, is the shape of the actual
/// question - which is not "which list is this id in" but "what may this
/// account do".
/// </summary>
public sealed class SettingsForm : Form
{
    private readonly string _configPath;
    private readonly string _bridgeRoot;
    private readonly bool _bridgeRunning;
    private readonly Func<bool>? _stopBeforeSave;

    private readonly TextBox _botToken = Theme.Input(400);
    private readonly CheckBox _showToken;
    private readonly TextBox _airServer = Theme.Input(220);
    private readonly NumericUpDown _airChannel = new() { Width = 90, Minimum = 0, Maximum = 999, Font = Theme.Ui, BorderStyle = BorderStyle.FixedSingle };
    private readonly Label _tokenNote = Theme.Hint("");

    private readonly ListView _accounts;
    private readonly TextBox _newId = Theme.Input(190);
    private readonly Label _accountsSummary = Theme.Hint("");
    private readonly Label _permissionsCaption = Theme.Caption("صلاحيات الحساب المحدَّد");
    private readonly Dictionary<string, CheckBox> _permissionChips = new(StringComparer.Ordinal);
    private readonly FlowLayoutPanel _permissionsRow;

    /// <summary>
    /// The five permission arrays. Label is what an operator reads; Key is the
    /// config.json property behind it. "Chat" rather than "group" on purpose:
    /// a chat id here is usually a private conversation, not a group.
    /// </summary>
    internal static readonly (string Key, string Label)[] Roles =
    {
        ("AllowedChatIds", "محادثة مسموحة"),
        ("AdminChatIds",   "محادثة إدارية"),
        ("AllowedUserIds", "مستخدم مسموح"),
        ("AdminUserIds",   "مستخدم إداري"),
        ("OwnerUserIds",   "مالك"),
    };

    /// <summary>
    /// The four lists Save-Config in Parts/Bridge.Core.ps1 declares as $managed.
    /// For every one of them the running bridge overwrites whatever is on disk
    /// with its own in-memory copy on its next save - so an edit made here
    /// while the bridge runs is reverted, silently, the first time anyone
    /// approves a user or changes a setting from Telegram. OwnerUserIds is
    /// absent on purpose: the bridge does not manage that one.
    /// </summary>
    internal static readonly string[] BridgeManagedKeys =
    {
        "AllowedChatIds", "AdminChatIds", "AllowedUserIds", "AdminUserIds"
    };

    internal static string RoleLabel(string key)
    {
        foreach (var role in Roles) if (role.Key == key) return role.Label;
        return key;
    }

    /// <summary>Only a negative id is certainly a group; everything else is a personal account.</summary>
    internal static string KindLabel(long id) => id < 0 ? "مجموعة" : "حساب";

    internal static bool IsUserRole(string roleKey) =>
        roleKey is "AllowedUserIds" or "AdminUserIds" or "OwnerUserIds";

    /// <summary>
    /// A group id cannot hold a user permission: those arrays are read as
    /// people, so a negative number in one of them grants nobody anything and
    /// says nothing about it. The reverse is fine and ordinary - a positive id
    /// in a chat array is a private conversation with the bot, which is what
    /// most of this installation's AllowedChatIds actually is.
    /// </summary>
    internal static bool RoleAppliesTo(long id, string roleKey) => !(id < 0 && IsUserRole(roleKey));

    /// <summary>The permission a freshly added id starts with, by what the id can be.</summary>
    internal static string DefaultRoleFor(long id) => id < 0 ? "AllowedChatIds" : "AllowedUserIds";

    /// <summary>Permissions in the canonical order, for the list column. Pure, so `--selftest` can pin it.</summary>
    internal static string PermissionSummary(IEnumerable<string> roleKeys)
    {
        var set = new HashSet<string>(roleKeys, StringComparer.Ordinal);
        var names = Roles.Where(r => set.Contains(r.Key)).Select(r => r.Label).ToList();
        return names.Count == 0 ? "— بلا صلاحيات —" : string.Join("، ", names);
    }

    /// <summary>Checks a newly typed id. Pure, so `--selftest` can pin the rules.</summary>
    internal static string? ValidateNewId(string? idText, IEnumerable<long> existing, out long id)
    {
        id = 0;
        var trimmed = (idText ?? "").Trim();
        if (trimmed.Length == 0) return "أدخل الرقم التعريفي أولًا.";
        if (!long.TryParse(trimmed, out id)) return "الرقم التعريفي أرقام فقط (وقد يبدأ بسالب للمجموعات).";
        if (id == 0) return "صفر ليس رقمًا تعريفيًا صالحًا.";
        if (existing.Contains(id)) return "هذا الحساب موجود في القائمة - حدّده وعدّل صلاحياته.";
        return null;
    }

    /// <summary>
    /// A token that is a DPAPI reference rather than the secret itself. The
    /// form used to show "dpapi:BotToken" as though it were the token, which
    /// invited the operator to "fix" it by pasting the real one - putting the
    /// secret back on disk in the clear, in an installation that had
    /// deliberately encrypted it.
    /// </summary>
    internal static bool LooksLikeDpapiReference(string? value) =>
        value is not null && value.StartsWith("dpapi:", StringComparison.Ordinal);

    /// <summary>Pure, so `--selftest` can pin it: only a running bridge makes a managed-list edit unsafe.</summary>
    internal static bool NeedsRestartToPersist(bool bridgeRunning, IEnumerable<string> changedKeys) =>
        bridgeRunning && changedKeys.Any(k => BridgeManagedKeys.Contains(k, StringComparer.Ordinal));

    internal static bool ShouldWriteLoadedValue(string loadedValue, string currentValue) =>
        !string.Equals(loadedValue, currentValue, StringComparison.Ordinal);

    /// <summary>id -> the permissions it holds. The list and the chips are both views of this.</summary>
    private readonly SortedDictionary<long, HashSet<string>> _model = new();

    private bool _tokenIsDpapiReference;
    private bool _syncingChips;
    private readonly Dictionary<string, string> _loaded = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> _loadedScalars = new(StringComparer.Ordinal);

    public bool RestartRequested { get; private set; }

    public SettingsForm(string configPath, string bridgeRoot, bool bridgeRunning = false, Func<bool>? stopBeforeSave = null)
    {
        _configPath = configPath;
        _bridgeRoot = bridgeRoot;
        _bridgeRunning = bridgeRunning;
        _stopBeforeSave = stopBeforeSave;

        Text = "إعدادات الجسر";
        Width = 780;
        Height = 900;
        MinimumSize = new Size(620, 560);
        StartPosition = FormStartPosition.CenterParent;
        FormBorderStyle = FormBorderStyle.Sizable;
        MaximizeBox = true;
        MinimizeBox = false;
        BackColor = Theme.Background;
        ForeColor = Theme.Text;
        Font = Theme.Ui;
        RightToLeft = RightToLeft.Yes;
        RightToLeftLayout = true;

        // FlatStyle.System, not Flat: a flat checkbox paints its glyph in the
        // parent's colours, which on the dark palette is dark on dark.
        _showToken = new CheckBox
        {
            Text = "إظهار",
            AutoSize = true,
            FlatStyle = FlatStyle.System,
            ForeColor = Theme.TextMuted,
            Font = Theme.UiSmall,
            Cursor = Cursors.Hand,
            Margin = new Padding(8, 6, 0, 0)
        };
        _airChannel.BackColor = Theme.SurfaceAlt;
        _airChannel.ForeColor = Theme.Text;

        if (!File.Exists(_configPath) && File.Exists(Path.Combine(_bridgeRoot, "config.example.json")))
        {
            var offer = MessageBox.Show(this,
                "لا يوجد config.json بعد. إنشاؤه من config.example.json؟",
                "لا يوجد ملف إعدادات", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (offer == DialogResult.Yes)
            {
                File.Copy(Path.Combine(_bridgeRoot, "config.example.json"), _configPath);
                // Freshly created from a template, it inherits the folder's
                // permissions - and it is about to hold the bot token.
                ProtectConfigAcl(_configPath);
            }
        }

        // ---- header --------------------------------------------------------
        var header = new Panel { Dock = DockStyle.Top, Height = 62, BackColor = Theme.Surface, Padding = new Padding(18, 10, 18, 10) };
        var headerHint = new Label { Dock = DockStyle.Top, Height = 18, Text = "هنا فقط ما لا يمكن تعديله من داخل البوت. باقي الإعدادات في إعدادات تيليجرام.", Font = Theme.UiSmall, ForeColor = Theme.TextMuted };
        var headerTitle = new Label { Dock = DockStyle.Top, Height = 22, Text = "إعدادات الجسر (config.json)", Font = Theme.SectionHeading, ForeColor = Theme.Text };
        header.Controls.Add(headerHint);
        header.Controls.Add(headerTitle);

        var layout = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
            Padding = new Padding(18, 6, 18, 18),
            BackColor = Theme.Background
        };

        void Field(string label, Control control, string? hint)
        {
            layout.Controls.Add(Theme.Caption(label));
            layout.Controls.Add(control);
            if (hint is not null) layout.Controls.Add(Theme.Hint(hint));
        }

        layout.Controls.Add(Theme.Heading("الاتصال"));

        // The token is masked by default. AGENTS.md states the rule plainly:
        // the manager must never display a token - the same rule the bridge
        // itself applies in Format-ConfigDiffValue. A control room is a room
        // with people in it, and screens get shared.
        _botToken.UseSystemPasswordChar = true;
        var tokenRow = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0), WrapContents = false };
        _showToken.CheckedChanged += (_, _) => _botToken.UseSystemPasswordChar = !_showToken.Checked;
        tokenRow.Controls.AddRange(new Control[] { _botToken, _showToken });
        Field("رمز البوت (BotToken)", tokenRow, null);
        layout.Controls.Add(_tokenNote);

        Field("عنوان محرك Air Pro", _airServer, "عنوان الجهاز الذي يعمل عليه المحرّك، مثل 127.0.0.1 إن كان على هذا الجهاز.");
        Field("رقم القناة", _airChannel, "رقم قناة Air Pro التي يتحكم بها الجسر.");

        // ---- accounts ------------------------------------------------------
        layout.Controls.Add(Theme.Heading("الحسابات والصلاحيات"));
        layout.Controls.Add(Theme.Hint("حساب واحد في كل صف. حدّده ثم اضبط صلاحياته بالأزرار أسفل القائمة."));

        _newId.PlaceholderText = "الرقم التعريفي…";
        var addButton = Theme.QuietButton("أضف");
        addButton.Width = 110;
        addButton.Click += (_, _) => AddAccount();
        // Enter inside the id box adds a row instead of hitting the form's
        // accept button and closing the dialog in the middle of an edit.
        _newId.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Enter) return;
            e.SuppressKeyPress = true;
            AddAccount();
        };

        var addRow = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = false, Margin = new Padding(0, 0, 0, 8) };
        addRow.Controls.AddRange(new Control[] { _newId, addButton });
        layout.Controls.Add(addRow);

        _accounts = new ListView
        {
            View = View.Details,
            FullRowSelect = true,
            MultiSelect = true,
            HideSelection = false,
            Width = 700,
            Height = 180,
            BackColor = Theme.Surface,
            ForeColor = Theme.Text,
            Font = Theme.Ui,
            BorderStyle = BorderStyle.FixedSingle,
            Margin = new Padding(0, 0, 0, 8)
        };
        _accounts.Columns.Add("الرقم التعريفي", 190);
        _accounts.Columns.Add("النوع", 110);
        _accounts.Columns.Add("الصلاحيات", 380);
        _accounts.SelectedIndexChanged += (_, _) => SyncChipsToSelection();
        _accounts.KeyDown += (_, e) => { if (e.KeyCode == Keys.Delete) RemoveSelected(); };
        layout.Controls.Add(_accounts);

        var removeButton = Theme.QuietButton("احذف المحدَّد");
        removeButton.Width = 155;
        removeButton.Click += (_, _) => RemoveSelected();
        layout.Controls.Add(removeButton);

        layout.Controls.Add(_permissionsCaption);
        _permissionsRow = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = true, Width = 700, Margin = new Padding(0, 0, 0, 4) };
        foreach (var role in Roles)
        {
            var chip = Theme.ToggleChip(role.Label);
            var key = role.Key;
            chip.CheckedChanged += (_, _) => OnPermissionToggled(key, chip.Checked);
            _permissionChips[key] = chip;
            _permissionsRow.Controls.Add(chip);
        }
        layout.Controls.Add(_permissionsRow);
        layout.Controls.Add(_accountsSummary);

        if (_bridgeRunning)
        {
            layout.Controls.Add(new Label
            {
                Text = "الجسر يعمل الآن. أربعًا من هذه الصلاحيات يديرها الجسر بنفسه،\n"
                     + "     فتعديلها يحتاج إعادة تشغيل ليثبت - وسيُعرض عليك ذلك عند الحفظ.",
                AutoSize = true,
                ForeColor = Theme.Pending,
                Font = Theme.UiSmall,
                Margin = new Padding(0, 8, 0, 0)
            });
        }

        // ---- buttons -------------------------------------------------------
        var buttons = new Panel { Dock = DockStyle.Bottom, Height = 60, BackColor = Theme.Surface, Padding = new Padding(18, 12, 18, 12) };
        var buttonFlow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, WrapContents = false };

        var saveRestartButton = Theme.PrimaryButton("حفظ وإعادة التشغيل", () => Theme.Accent);
        saveRestartButton.Width = 175;
        var saveButton = Theme.QuietButton("حفظ");
        saveButton.Width = 100;
        var cancelButton = Theme.QuietButton("إلغاء");
        cancelButton.Width = 100;
        cancelButton.DialogResult = DialogResult.Cancel;
        var openFileButton = Theme.QuietButton("فتح الملف في المفكرة");
        openFileButton.Width = 175;
        openFileButton.Enabled = !_bridgeRunning;
        if (_bridgeRunning) openFileButton.Text = "أوقف الجسر لفتح الملف";

        saveButton.Click += (_, _) => { if (Save(restarting: false)) DialogResult = DialogResult.OK; };
        saveRestartButton.Click += (_, _) => { if (Save(restarting: true)) { RestartRequested = true; DialogResult = DialogResult.OK; } };
        openFileButton.Click += (_, _) => Process.Start(new ProcessStartInfo("notepad.exe", $"\"{_configPath}\"") { UseShellExecute = true });

        buttonFlow.Controls.AddRange(new Control[] { saveRestartButton, saveButton, cancelButton, openFileButton });
        buttons.Controls.Add(buttonFlow);

        Controls.Add(layout);
        Controls.Add(buttons);
        Controls.Add(header);

        // Enter saves-and-restarts rather than plain-saves: with the bridge
        // running that is the option that actually makes an edit stick, and it
        // was plain Save on the old dialog that quietly threw the edit away.
        AcceptButton = _bridgeRunning ? saveRestartButton : saveButton;
        CancelButton = cancelButton;

        Load += (_, _) => LoadValues();
        Shown += (_, _) =>
        {
            var workingArea = Screen.FromControl(this).WorkingArea;
            Size = new Size(Math.Min(Width, workingArea.Width), Math.Min(Height, workingArea.Height));
        };
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Theme.ApplyTitleBar(Handle);
    }

    // ---- the accounts list -------------------------------------------------

    private void RefreshList(long? keepSelected = null)
    {
        _accounts.BeginUpdate();
        _accounts.Items.Clear();
        foreach (var (id, roles) in _model)
        {
            var item = new ListViewItem(id.ToString()) { Tag = id };
            item.SubItems.Add(KindLabel(id));
            item.SubItems.Add(PermissionSummary(roles));
            // An account nobody granted anything is almost certainly a
            // half-finished edit, not a decision - say so rather than saving
            // an id into none of the five arrays and leaving no trace of it.
            if (roles.Count == 0) item.ForeColor = Theme.Stopped;
            _accounts.Items.Add(item);
        }
        _accounts.EndUpdate();

        if (keepSelected is not null)
        {
            foreach (ListViewItem item in _accounts.Items)
            {
                if ((long)item.Tag! != keepSelected.Value) continue;
                item.Selected = true;
                item.EnsureVisible();
                break;
            }
        }
        UpdateSummary();
        SyncChipsToSelection();
    }

    private long? SelectedId =>
        _accounts.SelectedItems.Count == 1 ? (long)_accounts.SelectedItems[0].Tag! : null;

    /// <summary>
    /// Points the chips at whatever is selected. Guarded, because setting
    /// Checked here raises CheckedChanged, which would write the chip state
    /// straight back onto the model it was just read from.
    /// </summary>
    private void SyncChipsToSelection()
    {
        var id = SelectedId;
        _syncingChips = true;
        try
        {
            foreach (var (key, chip) in _permissionChips)
            {
                var applies = id is not null && RoleAppliesTo(id.Value, key);
                chip.Enabled = applies;
                chip.Checked = id is not null && _model.TryGetValue(id.Value, out var roles) && roles.Contains(key);
            }
        }
        finally { _syncingChips = false; }

        _permissionsCaption.Text = id is null
            ? (_accounts.SelectedItems.Count > 1 ? "حدّد حسابًا واحدًا لضبط صلاحياته" : "صلاحيات الحساب المحدَّد")
            : $"صلاحيات الحساب {id}";
        _permissionsCaption.ForeColor = id is null ? Theme.TextMuted : Theme.Text;
    }

    private void OnPermissionToggled(string roleKey, bool granted)
    {
        if (_syncingChips) return;
        var id = SelectedId;
        if (id is null) return;

        if (!_model.TryGetValue(id.Value, out var roles)) return;
        if (granted) roles.Add(roleKey); else roles.Remove(roleKey);

        // Only the selected row's text changes, so rebuild that row rather
        // than the whole list - a full refresh would drop the selection the
        // operator is still working in.
        foreach (ListViewItem item in _accounts.Items)
        {
            if ((long)item.Tag! != id.Value) continue;
            item.SubItems[2].Text = PermissionSummary(roles);
            item.ForeColor = roles.Count == 0 ? Theme.Stopped : _accounts.ForeColor;
            break;
        }
        UpdateSummary();
    }

    private void AddAccount()
    {
        var error = ValidateNewId(_newId.Text, _model.Keys, out var id);
        if (error is not null)
        {
            MessageBox.Show(this, error, "تحقّق", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            _newId.Focus();
            _newId.SelectAll();
            return;
        }

        _model[id] = new HashSet<string>(StringComparer.Ordinal) { DefaultRoleFor(id) };
        _newId.Clear();
        RefreshList(keepSelected: id);
        _newId.Focus();
    }

    private void RemoveSelected()
    {
        var selected = _accounts.SelectedItems.Cast<ListViewItem>().Select(i => (long)i.Tag!).ToList();
        if (selected.Count == 0)
        {
            MessageBox.Show(this, "اختر صفًّا أو أكثر من القائمة أولًا.", "لا يوجد تحديد",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        // Removing a row revokes somebody's access to the graphics that go on
        // air, and Delete on a focused list is easy to hit by accident. The
        // ids are named in the question because "3 accounts" is not enough for
        // anyone to notice they selected the wrong one.
        var names = string.Join("\n", selected.Select(id => $"  • {id}  ({PermissionSummary(_model[id])})"));
        var confirm = MessageBox.Show(this,
            $"سيُسحب الوصول من {selected.Count} حساب:\n\n{names}\n\nمتابعة؟",
            "تأكيد الحذف", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
        if (confirm != DialogResult.Yes) return;

        foreach (var id in selected) _model.Remove(id);
        RefreshList();
    }

    private void UpdateSummary()
    {
        var withNone = _model.Count(kv => kv.Value.Count == 0);
        var parts = Roles
            .Select(r => new { r.Label, Count = _model.Count(kv => kv.Value.Contains(r.Key)) })
            .Where(x => x.Count > 0)
            .Select(x => $"{x.Label}: {x.Count}");
        var joined = string.Join("  ·  ", parts);

        if (_model.Count == 0)
        {
            _accountsSummary.Text = "لا حسابات بعد - لن يستطيع أحد استخدام البوت.";
            _accountsSummary.ForeColor = Theme.Stopped;
            return;
        }
        _accountsSummary.Text = withNone > 0
            ? $"{_model.Count} حسابًا — {joined}   {withNone} بلا أي صلاحية"
            : $"{_model.Count} حسابًا — {joined}";
        _accountsSummary.ForeColor = withNone > 0 ? Theme.Pending : Theme.TextMuted;
    }

    /// <summary>The model flattened back into the shape config.json wants.</summary>
    private JsonArray IdsFor(string roleKey)
    {
        var array = new JsonArray();
        foreach (var (id, roles) in _model) if (roles.Contains(roleKey)) array.Add(id);
        return array;
    }

    /// <summary>A stable text form of one permission's ids, for spotting what the operator changed.</summary>
    private string Signature(string roleKey) =>
        string.Join(",", _model.Where(kv => kv.Value.Contains(roleKey)).Select(kv => kv.Key).OrderBy(i => i));

    // ---- load / save -------------------------------------------------------

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

            var rawToken = (string?)root["BotToken"] ?? "";
            _tokenIsDpapiReference = LooksLikeDpapiReference(rawToken);
            if (_tokenIsDpapiReference)
            {
                // Show nothing at all rather than the reference string, and
                // take the field out of play: the encrypted store is the only
                // place that can accept a new value, and it is not this form's
                // to write. Saving leaves the reference on disk untouched.
                _botToken.Text = "";
                _botToken.Enabled = false;
                _showToken.Enabled = false;
                _botToken.PlaceholderText = "محمي بـ DPAPI";
                _tokenNote.Text = "الرمز محمي بـ DPAPI ولا يُحرَّر من هنا - استخدم scripts\\Protect-BridgeSecrets.ps1.";
                _tokenNote.ForeColor = Theme.Running;
            }
            else
            {
                _botToken.Text = rawToken;
                _tokenNote.Text = "يُخزَّن في config.json كما هو. لتشفيره: scripts\\Protect-BridgeSecrets.ps1.";
            }

            _airServer.Text = (string?)root["AirServerAddress"] ?? "127.0.0.1";
            _airChannel.Value = Math.Clamp((int?)root["AirChannelNumber"] ?? 0, 0, 999);
            _loadedScalars["BotToken"] = rawToken;
            _loadedScalars["AirServerAddress"] = _airServer.Text.Trim();
            _loadedScalars["AirChannelNumber"] = ((int)_airChannel.Value).ToString(CultureInfo.InvariantCulture);

            _model.Clear();
            foreach (var role in Roles)
            {
                foreach (var id in ReadIds(root[role.Key]))
                {
                    if (!_model.TryGetValue(id, out var roles))
                    {
                        roles = new HashSet<string>(StringComparer.Ordinal);
                        _model[id] = roles;
                    }
                    roles.Add(role.Key);
                }
            }
            RefreshList();

            // Remembered so Save can tell what the operator actually changed,
            // and only warn about the permissions that are genuinely at risk.
            foreach (var role in Roles) _loaded[role.Key] = Signature(role.Key);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"تعذّرت قراءة config.json:\n{ex.Message}", "خطأ", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    /// <summary>Reads one id array, skipping anything that is not a number rather than throwing on it.</summary>
    internal static List<long> ReadIds(JsonNode? array)
    {
        var ids = new List<long>();
        if (array is not JsonArray arr) return ids;
        foreach (var node in arr)
        {
            if (node is null) continue;
            if (long.TryParse(node.ToString(), out var id)) ids.Add(id);
        }
        return ids;
    }

    /// <summary>Which permissions the operator actually edited in this sitting.</summary>
    private List<string> ChangedKeys() =>
        Roles.Select(r => r.Key)
             .Where(key => !_loaded.TryGetValue(key, out var was) || !string.Equals(was, Signature(key), StringComparison.Ordinal))
             .ToList();

    private bool Save(bool restarting)
    {
        if (!_tokenIsDpapiReference && string.IsNullOrWhiteSpace(_botToken.Text))
        {
            MessageBox.Show(this, "رمز البوت (BotToken) مطلوب.", "تحقّق", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            _botToken.Focus();
            return false;
        }

        // An id with no permission ticked lands in none of the five arrays, so
        // saving would drop it with no record that it was ever typed.
        var orphans = _model.Where(kv => kv.Value.Count == 0).Select(kv => kv.Key).ToList();
        if (orphans.Count > 0)
        {
            var answer = MessageBox.Show(this,
                $"{orphans.Count} حساب بلا أي صلاحية:\n\n  {string.Join("\n  ", orphans)}\n\n" +
                "لن تُحفظ هذه الحسابات لأنها لا تنتمي إلى أي قائمة.\n\nمتابعة الحفظ بدونها؟",
                "حسابات بلا صلاحيات", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (answer != DialogResult.Yes) return false;
        }

        // Plain Save, bridge running, one of the four managed permissions
        // edited: without this the write lands on disk, looks successful, and
        // is reverted by the bridge's next Save-Config.
        if (!restarting && NeedsRestartToPersist(_bridgeRunning, ChangedKeys()))
        {
            var answer = MessageBox.Show(this,
                "الصلاحيات التي عدّلتها يديرها الجسر وهو يعمل، فسيكتب نسخته فوقها عند أول حفظ منه " +
                "(موافقة مستخدم، أو تغيير إعداد من تيليجرام) ويضيع تعديلك.\n\n" +
                "نعم = حفظ وإعادة تشغيل الجسر ليثبت التعديل.\n" +
                "لا = حفظ الآن على أي حال.\n" +
                "إلغاء = العودة للتحرير.",
                "التعديل قد لا يثبت", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Warning);
            if (answer == DialogResult.Cancel) return false;
            if (answer == DialogResult.Yes) restarting = true;
        }

        try
        {
            var changedKeys = ChangedKeys().ToHashSet(StringComparer.Ordinal);
            RestartRequested = false;
            VerifyStoppedForSave(restarting, _stopBeforeSave ?? (() => !_bridgeRunning));
            WithConfigLock(@"Global\CinegyTelegramBridge.Config", () =>
            {
                var root = LoadRoot();
                // A DPAPI-protected token is left exactly as it sits on disk. Any
                // other value round-trips as before.
                // Only fields this operator actually edited are written back, so
                // a value the bridge changed on disk while the dialog was open
                // survives instead of being overwritten with a stale reading.
                if (!_tokenIsDpapiReference && ShouldWriteLoadedValue(_loadedScalars["BotToken"], _botToken.Text.Trim()))
                {
                    root["BotToken"] = _botToken.Text.Trim();
                }
                if (ShouldWriteLoadedValue(_loadedScalars["AirServerAddress"], _airServer.Text.Trim()))
                {
                    root["AirServerAddress"] = _airServer.Text.Trim();
                }
                var channel = ((int)_airChannel.Value).ToString(CultureInfo.InvariantCulture);
                if (ShouldWriteLoadedValue(_loadedScalars["AirChannelNumber"], channel))
                {
                    root["AirChannelNumber"] = (int)_airChannel.Value;
                }
                foreach (var role in Roles)
                {
                    if (changedKeys.Contains(role.Key)) root[role.Key] = IdsFor(role.Key);
                }

                var json = root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
                WriteConfigAtomically(json);
            });
            RestartRequested = restarting;
            return true;
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"تعذّر الحفظ:\n{ex.Message}", "خطأ", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return false;
        }
    }

    /// <summary>
    /// Temp file, then File.Replace - the same shape as Save-Config's
    /// ".tmp then Move-Item, keeping a .bak" in Parts/Bridge.Core.ps1, and for
    /// the same stated reason: a direct write that is cut short by a power cut
    /// leaves a truncated config.json, and since that file carries the bot
    /// token and the operator whitelist the bridge then refuses to start at
    /// all. File.Replace also keeps the destination's existing permissions,
    /// which a delete-and-recreate would throw away.
    /// </summary>
    private void WriteConfigAtomically(string json) => WriteConfigFile(_configPath, json);

    internal static void VerifyStoppedForSave(bool restarting, Func<bool> stop)
    {
        if (restarting && !stop())
            throw new IOException("تعذّر التحقق من توقف الجسر؛ لم تُحفظ الإعدادات.");
    }
    internal static void WithConfigLock(string mutexName, Action write)
    {
        using var mutex = new Mutex(false, mutexName);
        var acquired = false;
        try
        {
            try { acquired = mutex.WaitOne(TimeSpan.FromSeconds(10)); }
            catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) throw new IOException("انتهت مهلة انتظار ملف الإعدادات؛ حاول الحفظ مرة أخرى.");
            write();
        }
        finally { if (acquired) mutex.ReleaseMutex(); }
    }

    internal static void WriteConfigFile(string path, string json, Action<string>? protect = null)
    {
        var tempPath = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            // Create an empty file, restrict access, then introduce credentials.
            // ACL failure must leave both the original and its backup untouched.
            using (new FileStream(tempPath, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
            (protect ?? ProtectConfigAcl)(tempPath);
            File.WriteAllText(tempPath, json, new UTF8Encoding(false));
            if (File.Exists(path))
            {
                ProtectConfigAcl(path);
                if (File.Exists(path + ".bak")) ProtectConfigAcl(path + ".bak");
                File.Replace(tempPath, path, path + ".bak", ignoreMetadataErrors: false);
            }
            else File.Move(tempPath, path);
        }
        finally { if (File.Exists(tempPath)) File.Delete(tempPath); }
    }

    private static void ProtectConfigAcl(string path)
    {
        var sids = new List<IdentityReference>();
        using (var identity = WindowsIdentity.GetCurrent())
        {
            if (identity.User is null) throw new IOException("تعذّر تحديد مالك ملف الإعدادات.");
            sids.Add(identity.User);
        }
        sids.Add(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null));
        sids.Add(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null));
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sid in sids.Distinct())
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
    }
}

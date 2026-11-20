namespace CinegyBridge.Web.Endpoints;

// The public shape of the API. Web/openapi.json is generated from these at
// build time, and the client's types are generated from that file - so a
// change here that the client has not caught up with fails the gate.

public sealed record ErrorResponse(string Error, string? Message = null);
public sealed record CaptureCreateRequest(string Kind);
public sealed record OutputCapture(string Id, string State, string Kind, string Source, long CompletedAt, long ExpiresAt);

public sealed record ContentItem(string Title, string State, int? Rows, string? Id, bool? Enabled, Dictionary<string, string>? Values, UrgentItemTiming? Timing = null);
public sealed record ContentPage(IReadOnlyList<ContentItem> Items, int Page, int PageCount, int Total, int? Revision, IReadOnlyList<TemplateFieldDto>? Fields);
public sealed record BulletinField(string Name, string Label, string Kind);
public sealed record BulletinRow(string Id, Dictionary<string, string> Values, string[] Media, bool Skipped, string? ImageMode = null);
public sealed record BulletinImageChoice(string RowId, int RowNumber);
public sealed record BulletinPreviewRow(string Id, int Number, Dictionary<string, string> Values, string[] Media, bool Skipped,
    string? ImageMode, double? StartSeconds);
public sealed record BulletinPreview(int Revision, string Stamp, BulletinField[] Fields, BulletinPreviewRow[] Rows, int Page, int PageCount, int Total,
    bool PlaybackSupported, int PlannedCount, double? ExitSeconds, string? ImageField);
public sealed record BulletinEditor(string Id, string Name, string Design, int Revision, bool OnAir, bool PlaybackSupported, bool HeadlinePaste,
    BulletinField[] Fields, BulletinRow[] Rows, int Page, int PageCount, int Total, BulletinTiming? Timing,
    string? ImageField = null, BulletinImageChoice[]? ImageChoices = null, bool CanUploadPhoto = false);
public sealed record BulletinTiming(int DelayFrames, int IntroExtraFrames, int LastRowFrames, bool SyncToLoop,
    int LoopFrames, double Fps, int EffectiveIntroFrames, int EffectiveLastFrames, string FitNote);
public sealed record BulletinTimingInput(int? DelayFrames = null, int? IntroExtraFrames = null, int? LastRowFrames = null, bool? SyncToLoop = null);
public sealed record BulletinEditRequest(string Action, string? Id = null, int? Revision = null, int? Page = null,
    string? RowId = null, string? Name = null, string? Design = null, Dictionary<string, string>? Values = null,
    BulletinTimingInput? Timing = null, string? ImageMode = null, string? ImageSourceRowId = null);
public sealed record BulletinDesignOption(string Key, string Label);
public sealed record BulletinDesignOptions(BulletinDesignOption[] Designs);
public sealed record BulletinPasteRequest(string Action, string Id, int Revision, string Format, string Text, string? Review = null);
public sealed record BulletinPastePreview(string Review, BulletinField[] Fields, Dictionary<string, string>[] Rows, int[] SkippedLines);
public sealed record BulletinPasteResult(BulletinPastePreview? Preview, int? SavedPage);
public sealed record UrgentRowInput(Dictionary<string, string> Values, bool Enabled);
public sealed record UrgentItemTiming(int IntervalSeconds, int Repeats, string Mode);
public sealed record UrgentItemTimingInput(int? IntervalSeconds, int? Repeats, string? Mode);
public sealed record UrgentWriteRequest(string Action, int Revision, string? Id = null, UrgentRowInput? Row = null, UrgentItemTimingInput? Timing = null);
public sealed record UrgentPlaybackRequest(string Action, string[]? SelectedIds = null, string? Review = null, string? RunId = null, int? Step = null);
public sealed record UrgentRunStatus(string Id, string State, int Step, int StepCount, string Current, string Next);
public sealed record UrgentPreviewStep(string Text, double StartSeconds, double HoldSeconds);
public sealed record UrgentRunPreview(string Review, double TotalSeconds, int ItemCount, int StepCount, int Layer, bool ReplacesGraphic, string GraphicName, string[] Notes, UrgentPreviewStep[] Steps);
public sealed record UrgentPlaybackResponse(UrgentRunStatus? Run, UrgentRunPreview? Preview);
public sealed record UrgentManualRequest(string Action, string? ItemId = null, int? AutoHideSeconds = null, string? Review = null);
public sealed record UrgentManualPreview(string Review, int Layer, Dictionary<string, string> Values, int AutoHideSeconds,
    bool ReplacesGraphic, bool StopsRun, bool StopsBulletin, string GraphicName, bool Rehearsal = false);
public sealed record UrgentManualLive(string ItemId, int Layer, string Review);
public sealed record UrgentManualResponse(UrgentManualPreview? Preview = null, UrgentManualLive? Live = null, int[]? Durations = null,
    bool AutoHideFailed = false, bool CanRehearse = false, bool RehearsalStarted = false);
public sealed record UrgentTimingRequest(string Action, string? Revision = null, string? Field = null, int? Number = null, string? Option = null);
public sealed record UrgentTimingBounds(int Minimum, int Maximum);
public sealed record UrgentTimingState(string Revision, int IntervalSeconds, int Repeats, int TotalSeconds, int ExitGapSeconds,
    string Mode, string RepeatMode, double FloorSeconds, bool CanEdit, Dictionary<string, UrgentTimingBounds> Bounds);
public sealed record TickerDraftRequest(string Action, string? Revision = null, int? Index = null, string? Text = null, string? Review = null,
    long? PublishAtMs = null, int? PausedPage = null);
public sealed record TickerPausedPage(string[] Items, int Page, int PageCount, int Total, int Offset);
public sealed record TickerDraft(string Revision, string[] Items, DateTimeOffset? ScheduledAt, bool CanRemove, int MaxItems, TickerPausedPage Paused, bool CanClear);
public sealed record TickerConflict(string Review, string[] Items);
public sealed record TickerPastePreview(string Review, string[] Items, int Duplicates, int TooLong, int NoRoom, bool AtTop);
public sealed record TickerTxtPreview(string Review, string[] Items, string[] CurrentItems, int Duplicates, bool Identical, bool CancelsSchedule);
public sealed record TickerLockState(string? Revision, bool CanRequest, bool CanForce, bool Waiting, bool PreservesAtDeadline, string? Response, string? Requester, DateTimeOffset? ExpiresAt);
public sealed record TickerEditorState(string State, string Owner, int MaxItemLength, TickerDraft? Draft, TickerConflict? Conflict, bool SheetFailed, bool CanRestore, bool CanPullSheet, TickerPastePreview? Paste, TickerLockState? Lock);
public sealed record TickerSheetRequest(string Action, string Target, string? Review = null);
public sealed record TickerSheetPreview(string Review, string[] Items, string[] CurrentItems, bool Identical, bool CancelsSchedule);
public sealed record TickerBackupRequest(string Action, string? Id = null, string? Review = null, int? Page = null);
public sealed record TickerBackupItem(string Id, long SavedAt);
public sealed record TickerBackupPage(TickerBackupItem[] Items, int Page, int PageCount, int Total);
public sealed record TickerBackupPreview(string Review, long SavedAt, string[] Items, string[] CurrentItems, bool CurrentReadable, bool Identical, bool CancelsSchedule);
public sealed record TickerBackupResponse(TickerBackupPage? List, TickerBackupPreview? Preview);
public sealed record TickerSetRequest(string Action, int? Index = null, string? Revision = null, string? DraftRevision = null, string? Name = null);
public sealed record TickerSavedSet(int Index, string Name, string Revision, int Count, bool CanManage);
public sealed record TickerSetsState(string? DraftRevision, int MaxSets, TickerSavedSet[] Items);

public sealed record CurrentUser(long Id, string Name, string Role, string Method, bool WebOnly);

public sealed record SessionResponse(CurrentUser? User, string CsrfToken);

public sealed record PasswordSignInRequest(string Username, string Password);

public sealed record TelegramSignInResponse(string FlowId, string Code, string BotUsername, DateTimeOffset ExpiresAt);

/// <summary>State is pending, approved, denied, expired or unavailable.</summary>
public sealed record TelegramPollResponse(string State);

public sealed record BridgeUserResponse(long Id, string Name, string Role, bool WebOnly, string? Username);

public sealed record WebAccountResponse(
    string Username, long UserId, string DisplayName, bool WebOnly, string Role,
    DateTimeOffset CreatedAt, DateTimeOffset? LastLoginAt, DateTimeOffset? LockedUntil);

public sealed record AccountsResponse(IReadOnlyList<WebAccountResponse> Accounts, IReadOnlyList<BridgeUserResponse> BridgeUsers);

/// <summary>Kind is "telegram" (a password for an existing bot user, by
/// <see cref="UserId"/>) or "webOnly" (a new person with a <see cref="Role"/>).</summary>
public sealed record CreateAccountRequest(string Kind, string Username, string Password, string? DisplayName, long? UserId, string? Role);

public sealed record SetPasswordRequest(string Password);

public sealed record ChangePasswordRequest(string CurrentPassword, string NewPassword);

public sealed record SessionInfoResponse(
    string Id, long UserId, string Name, string Method, string Address, string Agent,
    DateTimeOffset CreatedAt, DateTimeOffset LastSeenAt, bool Current);

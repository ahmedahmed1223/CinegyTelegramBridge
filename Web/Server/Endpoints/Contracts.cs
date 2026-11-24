using System.Text.Json.Serialization;

namespace CinegyBridge.Web.Endpoints;

// The public shape of the API. Web/openapi.json is generated from these at
// build time, and the client's types are generated from that file - so a
// change here that the client has not caught up with fails the gate.

public sealed record ErrorResponse(string Error, string? Message = null);
public sealed record ProgrammeStatusItem(bool Listed, string Label, long? StartsAtMs, double? DurationSeconds, double? RemainingSeconds);
public sealed record ProgrammeNowNext(long CheckedAtMs, bool StatusAvailable, bool ScheduleAvailable,
    ProgrammeStatusItem? Current, ProgrammeStatusItem? Cued);
public sealed record CaptureCreateRequest(string Kind);
public sealed record TemplatePresetItem(int Index, string Name, Dictionary<string, string> Values, string[] HiddenFields);
public sealed record TemplatePresetPage(TemplatePresetItem[] Items, TemplateFieldDto[] Fields, int Page, int PageCount, string Revision, bool CanManage,
    Dictionary<string, string>? LastValues = null);
public sealed record TemplatePresetRequest(string Action, string Revision, int? Index = null, string? Name = null,
    Dictionary<string, string>? Values = null, int? Page = null);
public sealed record TemplateRehearsalRequest(string Key, string Action, string? Review = null);
public sealed record TemplateRehearsalField(string Label, string Value);
public sealed record TemplateRehearsalPreview(string Review, int Layer, int AutoHideSeconds, TemplateRehearsalField[] Fields);
public sealed record TemplateRehearsalResult(TemplateRehearsalPreview? Preview, bool AutoHideFailed = false);
public sealed record TemplateSceneEntry(string Name, string Path, bool Folder);
public sealed record TemplateSceneDefinition(string Key, string File, int Layer, string? Description = null, string? Category = null, string[]? Fields = null);
public sealed record TemplateCatalogueRequest(string Action, string? Folder = null, int? Page = null, string? Search = null,
    TemplateSceneDefinition? Definition = null, string? Review = null);
public sealed record TemplateCataloguePreview(string Review, string Key, string File, int Layer, string Description,
    string Category, string[] Fields, string[] SharedTemplates);
public sealed record TemplateCatalogueResult(string? Folder, TemplateSceneEntry[]? Entries, int? Page, int? PageCount,
    TemplateCataloguePreview? Preview);
public sealed record TemplateDefinitionFieldChange(string Name, string Label, int MaxLength, bool Required, bool Sensitive);
public sealed record TemplateDefinitionField(string Name, string Label, string Type, int MaxLength, bool Required, bool Sensitive);
public sealed record TemplateDefinitionChanges(string Description, string Category, int Layer, TemplateDefinitionFieldChange[] Fields)
{
    [System.Text.Json.Serialization.JsonNumberHandling(System.Text.Json.Serialization.JsonNumberHandling.Strict)]
    public int? ReminderMinutes { get; init; }
}
public sealed record TemplateDefinitionCommand(string Action, string Revision = "", string Review = "", TemplateDefinitionChanges? Changes = null);
public sealed record TemplateDefinitionView(string Key, string Revision, string File, int Layer, string Device,
    string Description, string Category, int PresetCount, TemplateDefinitionField[] Fields, int ReminderMinutes);
public sealed record TemplateDefinitionPreview(string Review, TemplateDefinitionView Before, TemplateDefinitionView? After);
public sealed record TemplateDefinitionResult(TemplateDefinitionView? Definition, TemplateDefinitionPreview? Preview);
public sealed record PersonalAirReminderRow(string Id, int Layer, string TemplateLabel, int ElapsedMinutes, DateTimeOffset FollowUpAt,
    bool ExpiresSilently);
public sealed record PersonalAirRemindersView(PersonalAirReminderRow[] Items, int SnoozeMinutes);
public sealed record PersonalAirReminderCommand(string Action);
public sealed record LayerNameView(int Layer, string Name, bool HasCustomName);
public sealed record LayerNamesPage(LayerNameView[] Items, int Page, int PageSize, int Total);
public sealed record LayerNameReviewCommand(string? Name);
public sealed record LayerNamePreview(LayerNameView Current, string Name, string Review, DateTimeOffset ExpiresAt);
public sealed record LayerNameConfirmCommand(string Review);
public sealed record TemplateFavoritesView(bool Enabled, string[] SelectedKeys, string[] PromotedKeys, string[] EligibleKeys);
public sealed record TemplateFavoriteCommand(bool? Selected);
public sealed record TemplateMaxAirView(string Key, int Seconds, string Revision);
public sealed record TemplateMaxAirReviewCommand(string Revision, string Mode)
{
    [System.Text.Json.Serialization.JsonNumberHandling(System.Text.Json.Serialization.JsonNumberHandling.Strict)]
    public int? Seconds { get; init; }
}
public sealed record TemplateMaxAirPreview(TemplateMaxAirView Current, int Seconds, string Review, DateTimeOffset ExpiresAt);
public sealed record TemplateMaxAirConfirm(string Review);
public sealed record TemplateMaxAirResult(string Key, int Seconds);
public sealed record OutputCapture(string Id, string State, string Kind, string Source, long CompletedAt, long ExpiresAt);

public sealed record ContentItem(string Title, string State, int? Rows, string? Id, bool? Enabled, Dictionary<string, string>? Values,
    UrgentItemTiming? Timing = null, int? Position = null);
public sealed record ContentPage(IReadOnlyList<ContentItem> Items, int Page, int PageCount, int Total, int? Revision,
    IReadOnlyList<TemplateFieldDto>? Fields, int? CollectionTotal = null);
public sealed record ProgrammeBoardSummary(string Id, string Name, int Rows);
public sealed record ProgrammeBoardList(ProgrammeBoardSummary[] Items, int Total, int Page, int PageCount, bool CanCreate);
public sealed record ProgrammeBoardTemplate(string Key, string Label, int Layer);
public sealed record ProgrammeBoardTemplates(ProgrammeBoardTemplate[] Templates);
public sealed record ProgrammeBoardField(string Name, string Label);
public sealed record ProgrammeBoardRow(string Id, int Number, Dictionary<string, string> Values, bool Enabled);
public sealed record ProgrammeBoardEditor(string Id, string Name, int Revision, bool CanEdit, bool CanManage, string EditRole, ProgrammeBoardField[] Fields,
    string[] SceneMedia, ProgrammeBoardRow[] Rows, int Total, int Page, int PageCount, int MaxFieldLength, string? LiveRowId,
    ProgrammeBoardRow? LiveRow = null, int? CollectionTotal = null);
public sealed record ProgrammeBoardEditRequest(string Action, string? Id = null, int? Revision = null, int? Page = null,
    string? RowId = null, Dictionary<string, string>? Values = null, string? Name = null, string? Template = null, string? Role = null);
public sealed record ProgrammeBoardPasteRequest(string Action, string Id, int Revision, string Format, string Text, string? Review);
public sealed record ProgrammeBoardPastePreview(string Review, ProgrammeBoardField[] Fields, Dictionary<string, string>[] Rows, int[] SkippedLines);
public sealed record ProgrammeBoardPasteResult(ProgrammeBoardPastePreview? Preview, int? SavedPage);
public sealed record ProgrammeBoardAirRequest(string Action, string Id, int Revision, string RowId, string? Review,
    Dictionary<string, string>? Values = null);
public sealed record ProgrammeBoardAirField(string Label, string Value);
public sealed record ProgrammeBoardAirPreview(string Review, int Layer, string Template, ProgrammeBoardAirField[] Fields,
    bool ReplacesGraphic, string? GraphicName, int? AutoHideSeconds, bool StopsUrgent = false, bool StopsBulletin = false);
public sealed record ProgrammeBoardAirResult(ProgrammeBoardAirPreview? Preview, string? LiveRowId, bool AutoHideFailed = false);
public sealed record BulletinField(string Name, string Label, string Kind);
public sealed record BulletinPhotoRowUpload(IFormFile Image, string Values);
public sealed record BulletinRow(string Id, Dictionary<string, string> Values, string[] Media, bool Skipped, string? ImageMode = null);
public sealed record BulletinImageChoice(string RowId, int RowNumber);
public sealed record BulletinPreviewRow(string Id, int Number, Dictionary<string, string> Values, string[] Media, bool Skipped,
    string? ImageMode, double? StartSeconds, string[]? ImageFields = null);
public sealed record BulletinPreview(int Revision, string Stamp, BulletinField[] Fields, BulletinPreviewRow[] Rows, int Page, int PageCount, int Total,
    bool PlaybackSupported, int PlannedCount, double? ExitSeconds, string? ImageField);
public sealed record BulletinScheduleItem(string Id, long ScheduledAtMs, string Status, bool CanCancel, string Reason);
public sealed record BulletinSchedulePage(BulletinScheduleItem[] Items, bool CanSchedule, int Page, int PageCount);
public sealed record BulletinRun(string Id, string State, int Row, int RowCount);
public sealed record BulletinPlayback(bool CanStart, bool Busy, BulletinRun? Run = null, string? Review = null,
    int? Layer = null, bool? Replacing = null, bool? PausesTicker = null, bool CanQueueAfterUrgent = false);
public sealed record BulletinPlaybackRequest(string Action, string Id, int? Revision = null, string? Stamp = null,
    string? Review = null, string? RunId = null);
public sealed record BulletinScheduleRequest(string Action, string Id, int? Revision = null, long? ScheduledAtMs = null,
    string? ScheduleId = null, int? Page = null);
public sealed record BulletinEditor(string Id, string Name, string Design, int Revision, bool OnAir, bool PlaybackSupported, bool HeadlinePaste,
    BulletinField[] Fields, BulletinRow[] Rows, int Page, int PageCount, int Total, BulletinTiming? Timing,
    string? ImageField = null, BulletinImageChoice[]? ImageChoices = null, bool CanUploadPhoto = false, string[]? PhotoFields = null);
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
public sealed record UrgentPlaybackRequest(string Action, string[]? SelectedIds = null, string? Review = null, string? RunId = null, int? Step = null, string? Mode = null);
public sealed record UrgentRunStatus(string Id, string State, int Step, int StepCount, string Current, string Next);
public sealed record UrgentPreviewStep(string Text, double StartSeconds, double HoldSeconds);
public sealed record UrgentRunPreview(string Review, double TotalSeconds, int ItemCount, int StepCount, int Layer, bool ReplacesGraphic, string GraphicName, string[] Notes, UrgentPreviewStep[] Steps);
public sealed record UrgentPlaybackResponse(UrgentRunStatus? Run, UrgentRunPreview? Preview);
public sealed record UrgentManualRequest(string Action, string? ItemId = null, int? AutoHideSeconds = null, string? Review = null);
public sealed record UrgentManualPreview(string Review, int Layer, Dictionary<string, string> Values, int AutoHideSeconds,
    bool ReplacesGraphic, bool StopsRun, bool StopsBulletin, string GraphicName, bool Rehearsal = false);
public sealed record UrgentManualLive(string ItemId, int Layer, string Review);
public sealed record UrgentManualResponse(UrgentManualPreview? Preview = null, UrgentManualLive? Live = null, int[]? Durations = null,
    bool AutoHideFailed = false, bool CanRehearse = false, bool RehearsalStarted = false, bool? SceneConfirmed = null, string? NoticeId = null);
public sealed record UrgentTimingRequest(string Action, string? Revision = null, string? Field = null, int? Number = null, string? Option = null);
public sealed record UrgentTimingBounds(int Minimum, int Maximum);
public sealed record UrgentTimingState(string Revision, int IntervalSeconds, int Repeats, int TotalSeconds, int ExitGapSeconds,
    string Mode, string RepeatMode, double FloorSeconds, bool CanEdit, Dictionary<string, UrgentTimingBounds> Bounds);
public sealed record TickerDraftRequest(string Action, string? Revision = null, int? Index = null, string? Text = null, string? Review = null,
    long? PublishAtMs = null, int? PausedPage = null, int? Destination = null);
public sealed record TickerPausedPage(string[] Items, int Page, int PageCount, int Total, int Offset);
public sealed record TickerDraft(string Revision, string[] Items, DateTimeOffset? ScheduledAt, bool CanRemove, int MaxItems, TickerPausedPage Paused, bool CanClear,
    string? SharedDraftKey = null, string[]? RowKeys = null, bool? CanManage = null);
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
public sealed record TelegramAccessItem(long ChatId, long UserId, string Name, DateTimeOffset RequestedAt, DateTimeOffset ExpiresAt);
public sealed record TelegramAccessPage(TelegramAccessItem[] Requests, int Page, int PageSize, int Total, bool RejectionBlocks);
public sealed record TelegramAccessReview(TelegramAccessItem Request, string Decision, bool RejectionBlocks, string Review);
public sealed record TelegramAccessDecision(long ChatId, long UserId, string Decision);
public sealed record TelegramAccessReviewCommand(string Decision);
public sealed record TelegramAccessDecisionCommand(string Decision, string Review);
public sealed record TelegramAccessRoleCommand(string Role, string ExpectedRole);
public sealed record TelegramAccessRole(long UserId, string Role);

public sealed record PendingTemplateSchedule(string Id, string Key, int Layer, long ScheduledAtMs,
    string StationTime, string StationTimeZone, string Recurrence, string RecurrenceUntil,
    string Revision = "", bool CanManage = false, string AnchorMaterialId = "", int AnchorOffsetSeconds = 0);
public sealed record TemplateSchedulePage(PendingTemplateSchedule[] Items, int Page, int PageCount, int Total,
    string StationTimeZone, int StationOffsetMinutes, string StationTime, bool ClockValid, bool Paused, bool MaterialsEnabled = false);
public sealed record TemplateScheduleField(string Name, string Label, bool Sensitive, string? Value);
public sealed record TemplateScheduleReview(string Review, string Key, int Layer, long ScheduledAtMs, string StationTime,
    string StationTimeZone, string Recurrence, string RecurrenceUntil, int ConflictCount, PendingTemplateSchedule[] Conflicts,
    TemplateScheduleField[] Fields, string Operation = "create", string AnchorMaterialId = "",
    int AnchorOffsetSeconds = 0, string AnchorMaterialName = "");
public sealed record TemplateScheduleReviewCommand(string? Key = null, string? Time = null, string Recurrence = "once",
    string? RecurrenceUntil = null, Dictionary<string, string>? Variables = null, string? Operation = null,
    string? ScheduleId = null, string? Revision = null, string? AnchorMaterialId = null, int? AnchorOffsetSeconds = null);
public sealed record TemplateScheduleConfirmCommand(string Review);
public sealed record SelfTestReadinessReport(int? Layer, bool HasRegisteredTemplate, string Engine,
    long? ObservedAt, IReadOnlyList<string> Findings);
public sealed record UsageSummaryTemplate(string Name, int Uses, long? LastUsedAt);
public sealed record AdminUsageSummaryReport(long CapturedAt, long StartedAt, int Successful, int Failed, int Blocked,
    int SevenDayOperations, double DailyAverage, bool SevenDayTruncated, IReadOnlyList<UsageSummaryTemplate> Templates);
public sealed record LayerComparisonTarget(int Layer, string Name);
public sealed record LayerComparisonTargets(IReadOnlyList<LayerComparisonTarget> Layers);
public sealed record LayerComparison(int Layer, bool Tracked, bool? EngineActive, bool CanReviewForget, string Disposition, long ObservedAt, bool CanReviewReplace = false);
public sealed record LayerAdoptionReview(string Review, int Layer, string TemplateKey);
public sealed record LayerAdoptionConfirmCommand(string Review);
public sealed record LayerAdoptionResult(int Layer, bool Adopted);
public sealed record LayerForgetReview(string Review, int Layer, string TemplateKey);
public sealed record LayerForgetConfirmCommand(string Review);
public sealed record LayerForgetResult(int Layer, bool Forgotten);
public sealed record LayerReplacementReview(string Review, int Layer, string OldTemplateKey, string TemplateKey);
public sealed record LayerReplacementConfirmCommand(string Review);
public sealed record LayerReplacementResult(int Layer, bool Replaced);
public sealed record ScheduleHoldReviewCommand(bool? Paused);
public sealed record ScheduleHoldReview(string Review, bool CurrentlyPaused, bool Paused, int PendingAppointments, bool Maintenance);
public sealed record ScheduleHoldResult(bool Paused, int PendingAppointments, bool Maintenance);
public sealed record ScheduleMaterialItem(string Id, string Name, long StartsAtMs, string StationTime, double DurationSeconds,
    bool Active, bool CanAnchor);
public sealed record ScheduleMaterialPage(ScheduleMaterialItem[] Items, int Page, int PageCount, int Total, bool ActiveKnown,
    string StationTimeZone);

public sealed record AirRerunCommand(string Kind, string Action, Dictionary<string, string>? Variables = null, string? Review = null);
public sealed record AirRerunField(string Name, string Label, bool Required, bool Sensitive, int? MaxLength, string? Value, bool HasValue);
public sealed record AirRerunPlan(string Key, int Layer, int AutoHideSeconds, AirRerunField[] Fields,
    bool? ReplacesGraphic, string? GraphicName, string? Review);
public sealed record AirRerunResult(AirRerunPlan? Rerun, bool? SceneConfirmed);

public sealed record AccessHistoryDecision(string UserId, string Decision, long DecidedAt, string? DecidedByUserId, long? RequestedAt);
public sealed record AccessHistoryPage(AccessHistoryDecision[] Items, int Page, int PageSize, int Total, bool Truncated);
public sealed record RestartReadiness(long CheckedAt, string State, int ActiveScenes, bool ManagedRestartAvailable, bool RelayBlocksRestart);
public sealed record ManagedRestartReviewCommand(string Id);
public sealed record ManagedRestartReceiptCommand(string Id, string Receipt);
public sealed record ManagedRestartResult(string Id, string State, string Receipt, int ActiveScenes);

public sealed record AdminOverviewSetting(
    string Id, string Category, string Kind, string Label, string Description, string Unit,
    bool? Enabled, int? Value, int? Minimum, int? Maximum, bool Protected, bool Editable);
public sealed record AdminOverviewServices(
    string TelegramState, int TelegramFailures, string CinegyState, long CinegyLastReadAt, bool CinegyFresh,
    string OutputMonitorState, string RelayState, bool SchedulePaused, int QuarantinedChats);
public sealed record AdminOverviewActivity(
    int RecentOperationsToday, int ActiveOperatorsToday, int OnAirLayers, int PendingRequests, int ScheduledEvents);
public sealed record AdminOverview(
    string Version, long StartedAt, long PublishedAt, AdminOverviewServices Services,
    AdminOverviewActivity Activity, AdminOverviewSetting[] Settings);
public sealed record AdminSettingReviewCommand(bool? Enabled, int? Value);
public sealed record AdminSettingConfirmCommand(string Review);
public sealed record AdminSettingPreview(AdminOverviewSetting Setting, bool? Enabled, int? Value, string Review);
public sealed record AdminSettingResult(AdminOverviewSetting Setting);

public sealed record WebEditableSettingsValues(
    [property: JsonPropertyName("NotifyAdminsOnAccessRequest"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    bool? NotifyAdminsOnAccessRequest = null,
    [property: JsonPropertyName("AskRequesterName"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    bool? AskRequesterName = null,
    [property: JsonPropertyName("MaxPendingApprovals"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? MaxPendingApprovals = null,
    [property: JsonPropertyName("PendingStateTimeoutMinutes"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? PendingStateTimeoutMinutes = null,
    [property: JsonPropertyName("OneHandMode"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    bool? OneHandMode = null,
    [property: JsonPropertyName("EnablePersistentMenuButton"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    bool? EnablePersistentMenuButton = null,
    [property: JsonPropertyName("NewsMaxItems"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? NewsMaxItems = null,
    [property: JsonPropertyName("NewsDraftTimeoutMinutes"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? NewsDraftTimeoutMinutes = null,
    [property: JsonPropertyName("UrgentBoardIntervalSeconds"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? UrgentBoardIntervalSeconds = null,
    [property: JsonPropertyName("UrgentBoardRepeats"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? UrgentBoardRepeats = null,
    [property: JsonPropertyName("UrgentBoardTotalSeconds"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? UrgentBoardTotalSeconds = null,
    [property: JsonPropertyName("UrgentBoardMaxItems"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? UrgentBoardMaxItems = null,
    [property: JsonPropertyName("UrgentBoardMaxTextLength"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? UrgentBoardMaxTextLength = null,
    [property: JsonPropertyName("UrgentBoardNotifyOnFinish"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    bool? UrgentBoardNotifyOnFinish = null,
    [property: JsonPropertyName("MojazRowFrames"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? MojazRowFrames = null,
    [property: JsonPropertyName("MojazIntroExtraFrames"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? MojazIntroExtraFrames = null,
    [property: JsonPropertyName("MojazLastRowFrames"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? MojazLastRowFrames = null,
    [property: JsonPropertyName("MojazNotifyOnFinish"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    bool? MojazNotifyOnFinish = null,
    [property: JsonPropertyName("TemplateReminderFollowUpMinutes"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? TemplateReminderFollowUpMinutes = null,
    [property: JsonPropertyName("SchedulePreNotifyMinutes"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? SchedulePreNotifyMinutes = null,
    [property: JsonPropertyName("MojazScheduleNoticeSeconds"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? MojazScheduleNoticeSeconds = null);

public sealed record WebSettingsImportChange(string Id, string Kind, bool? BeforeEnabled, bool? AfterEnabled, int? BeforeValue, int? AfterValue);
public sealed record WebSettingsImportPreview(WebSettingsImportChange[] Changes, string? Review);
public sealed record WebSettingsImportResult(int Applied);
public sealed record WebSettingsBackup(string Id, long SavedAt, string Kind);
public sealed record WebSettingsBackupList(WebSettingsBackup[] Items, bool Truncated);
public sealed record WebSettingsRecoveryReviewCommand(string Source, string? Backup = null);

public sealed record WebEditableSettingsExport(
    [property: JsonPropertyName("Kind")] string Kind,
    [property: JsonPropertyName("BridgeVersion")] string BridgeVersion,
    [property: JsonPropertyName("ExportedAt")] DateTimeOffset ExportedAt,
    [property: JsonPropertyName("Settings")] WebEditableSettingsValues Settings);
public sealed record AirMaintenanceCommand(string Action, bool? Enabled = null, string? Review = null);
public sealed record AirMaintenanceState(bool ManualEnabled, bool WindowActive, bool EffectiveBlocked,
    string? WindowStart, string? WindowEnd, bool? RequestedEnabled, bool? EffectiveAfter, string? Review);
public sealed record AirMaintenanceResult(AirMaintenanceState Maintenance);
public sealed record EmergencyHideCommand(string Action, string? Review = null);
public sealed record EmergencyHideTarget(int Layer, string Name);
public sealed record EmergencyHidePreview(string Review, EmergencyHideTarget[] Targets, int[] BlockedLayers);
public sealed record EmergencyHideReceipt(int Layer, string Status);
public sealed record EmergencyHideResult(EmergencyHidePreview? Preview, EmergencyHideReceipt[]? Results);
public sealed record HideAllScopeLayer(int Id, string Name);
public sealed record HideAllLayerScopeView(string Mode, int[] SelectedLayers, HideAllScopeLayer[] KnownLayers, string Revision,
    bool Enabled, bool CanManage);
public sealed record HideAllScopeReviewCommand(string Revision, string Mode)
{
    [System.Text.Json.Serialization.JsonNumberHandling(System.Text.Json.Serialization.JsonNumberHandling.Strict)]
    public int[]? Layers { get; init; }
}
public sealed record HideAllScopePreview(HideAllLayerScopeView Current, string Mode, int[] SelectedLayers, string Review, DateTimeOffset ExpiresAt);
public sealed record HideAllScopeConfirmCommand(string Review);
public sealed record AirLayerRemovalCommand(string Action, string Operation, string? Review = null);
public sealed record AirLayerRemovalPreview(string Review, int Layer, string Operation, string TemplateKey, long ExpiresAt);
public sealed record AirLayerRemovalResult(AirLayerRemovalPreview? Preview, bool? Sent);
public sealed record AirRollbackCommand(string Action, int? Layer = null, string? Review = null);
public sealed record AirRollbackPlan(int Layer, string Action, string TemplateKey, long ExpiresAt, string? CurrentName, string? Review);
public sealed record AirRollbackResult(AirRollbackPlan[]? Candidates, AirRollbackPlan? Preview, bool? SceneConfirmed);
public sealed record AirTextCommand(string Action, Dictionary<string, string>? Values = null, string? Review = null);
public sealed record AirTextField(string Name, string Label, bool Required, int? MaxLength, string LastKnownValue);
public sealed record AirTextChange(string Name, string Label, string Value);
public sealed record AirTextPlan(int Layer, string TemplateKey, AirTextField[] Fields, AirTextChange[]? Changes, string? Review);
public sealed record AirTextResult(AirTextPlan? Plan, bool? Accepted);
public sealed record AirTimerCommand(string Action, int? Seconds = null, int? AdjustSeconds = null, string? Review = null);
public sealed record AirTimerPlan(int Layer, string TemplateKey, int[] Choices, long? CurrentHideAt, long? MaximumHideAt, long? ProposedHideAt, string? Review);
public sealed record AirTimerResult(AirTimerPlan? Plan, long? HideAt);
public sealed record AnnouncementAdminItem(
    string Id, string Text, string Scope, string Status, long CreatedAt, long ExpiresAt, long LastSentAt,
    int RepeatHours, bool RequireAck, bool Pinned, int ReadCount);
public sealed record AnnouncementAdminPage(
    AnnouncementAdminItem[] Items, int Page, int PageSize, int Total, bool Enabled, int MaxLength, int DefaultExpiryHours);
public sealed record AnnouncementReviewCommand(string Text, string Scope, int ExpiryHours, int RepeatHours, bool RequireAck, bool Pinned);
public sealed record AnnouncementConfirmCommand(string Review);
public sealed record AnnouncementPreview(
    string Text, string Scope, int ExpiryHours, int RepeatHours, bool RequireAck, bool Pinned, int AudienceCount, string Review);
public sealed record AnnouncementCancelPreview(AnnouncementAdminItem Item, string Review);
public sealed record AnnouncementCancelResult(AnnouncementAdminItem Item, bool Persisted);
public sealed record BulletinAfterUrgentReviewCommand(string Id, int Revision);
public sealed record BulletinAfterUrgentConfirmCommand(string Review);
public sealed record BulletinAfterUrgentReview(string Id, int Revision, string Name, int RowCount, int UrgentLayer, string Review);
public sealed record BulletinAfterUrgentResult(string Id, bool AlreadyQueued);
public sealed record BulletinManagementReviewCommand(string Id, int Revision, string Operation);
public sealed record BulletinManagementConfirmCommand(string Review);
public sealed record BulletinManagementReview(string Id, int Revision, string Operation, string Name,
    int RowCount, int PendingCount, int ReferenceCount, string Review);
public sealed record BulletinManagementResult(string Id, string Operation, int? Revision);
public sealed record BulletinReportRun(string Name, string OperatorName, string Started, string Ended, string Duration, int Rows, bool Scheduled);
public sealed record BulletinReportPage(string Period, string Scope, int Total, int Rows, int Operators, int Scheduled, bool Truncated,
    int Page, int PageCount, BulletinReportRun[] Items);
public sealed record BulletinReportExport(string Html, int Count, int Total, bool Truncated);
public sealed record BulletinSceneImageChoice(int Slot, string Label, long Bytes);
public sealed record BulletinSceneImagePage(string Selection, int Page, int PageCount, bool Truncated,
    IReadOnlyList<BulletinSceneImageChoice> Items);
public sealed record BulletinSceneImageApply(string Id, string RowId, int Revision, string Selection, int Slot);
public sealed record RuntimeFileDiagnostic(string Kind, string State, double SizeKilobytes, long ModifiedAt, bool HasBackup);
public sealed record RuntimeFileDiagnostics(long CheckedAt, int ParseLimitBytes, RuntimeFileDiagnostic[] Items);
public sealed record EngineHealthReading(
    bool Enabled, long? CheckedAtMs, long? ElapsedMs, string? Health, string? License, int? SampleCount,
    long? OutputFrames, long? DroppedFrames, long? DroppedSampleIncrease, long? InputLossFrames,
    double? MeanReadMs, double? MaxReadErrorPercent);
public sealed record OperationMetrics(long CheckedAt, long StartedAt, long UptimeSeconds, string State,
    DiagnosticAirOperations AirOperations, int TelegramRateLimitHits, int TelegramOutboxDropped, string TelegramState,
    string CinegyState, string? LastHeartbeatDate, int OnAirCount, int? RichPayloadPeakPercent);

public sealed record DiagnosticAirOperations(int Success, int Failed, int Blocked);
public sealed record DiagnosticTimelineEvent(long AtMs, string Severity, string Category, string Action, string Outcome);
public sealed record DiagnosticTimeline(string State, bool Truncated, int ByteLimit, int LineLimit, DiagnosticTimelineEvent[] Items);
public sealed record RuntimeDiagnosticBundle(int SchemaVersion, long GeneratedAtMs, string BridgeVersion, string PowershellVersion,
    long UptimeSeconds, double WorkingSetMB, double PrivateMemoryMB, double? DiskFreeGB, bool LowDisk,
    DiagnosticAirOperations AirOperations, RuntimeFileDiagnostics RuntimeFiles, DiagnosticTimeline Timeline);
public sealed record ShiftReadinessReport(long CheckedAt, bool Ready, int OnAirLayers, int PendingOperations,
    string TickerDraft, int QuarantinedChats, int PinnedFaults, bool QuietHours, string[] ProtectionFindings);
public sealed record AdminNotificationCoverage(long CheckedAt, int Matched, int WithoutPersonalChat, int WithoutAdminRights);
public sealed record ScheduleExecutionItem(string Kind, string Label, int Layer, string Result, int Attempt, long DurationMs,
    long? RanAtMs, long? DueAtMs, string RanAtStation, string DueAtStation, long? DelaySeconds, string Reason);
public sealed record ScheduleExecutionPage(ScheduleExecutionItem[] Items, int Page, int PageCount, int Total, int ReadLimit,
    string StationTimeZone);
public sealed record ShiftHistoryItem(string Reference, string Event, long AtMs, string StationTime, string Action,
    string Target, string Result, int Layer, long DurationMs, string OperatorId, string OperatorName);
public sealed record RelayDestinationReviewRequest(string Revision, string Destination);
public sealed record RelayDestinationConfirmRequest(string Revision, string Destination, string Review);
public sealed record RelayDestinationReview(string Review);

public sealed record OperationReferenceItem(long AtMs, string StationTime, string Action, string Result, int Layer, long DurationMs);
public sealed record OperationReferenceLookup(string Status, int ReadLimit, bool Truncated, OperationReferenceItem[] Items);
public sealed record ShiftHistoryOption(string Value, string Label, int Count);
public sealed record ShiftHistoryOperatorOption(string Value, string Label, int Count);
public sealed record ShiftHistoryEventOption(string Value, string Label, int Count);
public sealed record ShiftHistoryPage(ShiftHistoryItem[] Items, int Page, int PageCount, int Total, bool Truncated,
    string StationTimeZone, ShiftHistoryOption[] Targets, ShiftHistoryOperatorOption[] Operators, ShiftHistoryEventOption[] Kinds,
    int HiddenTargets, int HiddenOperators);
public sealed record ShiftHistoryExport(string Csv, int Count, bool Truncated);
public sealed record AirNoticeEvent(string Id, string Action, string Key, int Layer, long At);
public sealed record PersonalAirNotice(bool TelegramAvailable, bool? Muted, AirNoticeEvent[]? Events = null);
public sealed record PersonalAirNoticeChange(bool? Muted, bool? ExpectedMuted);
public sealed record TemplateAirNoticeRule(string Key, string Scope, bool CanChange);
public sealed record TemplateAirNoticePage(TemplateAirNoticeRule[] Items, int Page, int PageCount, int Total);
public sealed record TemplateAirNoticeChange(string Scope, string ExpectedScope, int? Page = null);
public sealed record TelegramRevokeTarget(long Id, string Name, string Role);
public sealed record TelegramRevokePreview(TelegramRevokeTarget Target, string Review);
public sealed record TelegramRevokeConfirmCommand(string Review);
public sealed record TelegramRevokeResult(long UserId, bool Persisted);
public sealed record TelegramSuspensionTarget(long Id, string Name, bool Disabled);
public sealed record SuspendedTelegramOperatorsPage(TelegramSuspensionTarget[] Items, int Page, int PageSize, int Total);
public sealed record TelegramSuspensionReviewCommand(bool? Disabled);
public sealed record TelegramSuspensionConfirmCommand(string Review);
public sealed record TelegramSuspensionPreview(TelegramSuspensionTarget Target, bool Disabled, string Review);
public sealed record TelegramSuspensionResult(long UserId, bool Disabled, bool Persisted);
public sealed record BlockedAccessItem(long ChatId, long BlockedAt, string Reason, string BlockedBy);
public sealed record BlockedAccessPage(BlockedAccessItem[] Items, int Page, int PageSize, int Total);
public sealed record AccessUnblockPreview(BlockedAccessItem Item, string Review);
public sealed record AccessUnblockCommand(string Review);
public sealed record AccessUnblockResult(long ChatId);
public sealed record TemplateRegistryExportReview(string Review, int Templates, long Bytes);
public sealed record TemplateRegistryExportDownload(string Review);
public sealed record TemplateRegistryImportReview(string Review, int Templates, int Added, int Changed, int Removed, int Unchanged);
public sealed record TemplateBackupCommand(string Action, string? Id = null, string? Review = null);
public sealed record TemplateBackupSummary(string Id, long SavedAt, long Bytes);
public sealed record TemplateBackupPreview(string Id, string[] Added, string[] Changed, string[] Removed, string Review);
public sealed record TemplateBackupResult(TemplateBackupSummary[]? Backups, bool? Truncated, TemplateBackupPreview? Preview, bool? Restored);
public sealed record TemplateSceneReplacementCommand(string Action, string? Revision = null, string? File = null, string? Selection = null, string? Review = null);
public sealed record TemplateSceneReplacementCurrent(string Key, string File, int Layer, string Revision, int PresetCount);
public sealed record TemplateSceneReplacementSelection(string? Handle, string File, string[] IncompatibleFields);
public sealed record TemplateSceneReplacementPreview(string Review, string Key, int Layer, string BeforeFile, string AfterFile, string[] Fields, int PresetCount);
public sealed record TemplateSceneReplacementResult(TemplateSceneReplacementCurrent? Current, TemplateSceneReplacementSelection? Selection,
    TemplateSceneReplacementPreview? Preview);
public sealed record WorkSummaryResponse(
    string Period, string Scope, bool Truncated, int Operators, int Operations, int Successful, int Blocked, int Failed, int Shows);

public sealed record TickerReportDay(string Date, int Publishes, int Items, string First, string Last,
    string Range, string Edits, string Operators);
public sealed record TickerReportResponse(string Period, string Scope, int Publishes, int Items, int SilentDays,
    string LastPublishedAt, bool Truncated, TickerReportDay[] Days);
public sealed record TickerReportExport(string Html, int Days, int Publishes, bool Truncated);

public sealed record TelegramOperatorActivityTotals(int Operations, int Successful, int Blocked, int Failed, int Shows, bool Truncated);
public sealed record TelegramOperatorActivity(long UserId, string State, int? AgeMinutes, int RecentMinutes, TelegramOperatorActivityTotals Today);
public sealed record TelegramPresenceItem(string Name, string Role, bool Disabled, string State, long? LastSeenAt);
public sealed record TelegramPresencePage(int Page, int PageSize, int PageCount, int Total, int RecentMinutes, long CapturedAt, IReadOnlyList<TelegramPresenceItem> Items);
public sealed record TelegramDeliveryQuarantineRow(long ChatId, DateTimeOffset? Since, int Strikes, bool CanReset);
public sealed record TelegramDeliveryQuarantinePage(TelegramDeliveryQuarantineRow[] Items, int Page, int PageSize, int Total);
public sealed record TelegramDeliveryQuarantineReview(TelegramDeliveryQuarantineRow Target, string Review, DateTimeOffset ExpiresAt);
public sealed record TelegramDeliveryQuarantineConfirm(string Review);
public sealed record TelegramDeliveryQuarantineReset(long ChatId);
public sealed record TemplateIssueCommand(string Action, string? Id = null, string? Review = null);
public sealed record TemplateIssueItem(string Id, string Name, string Reason, int Layer, bool CanReview);
public sealed record TemplateIssuePreview(TemplateIssueItem Issue, string Review);
public sealed record TemplateIssueResult(TemplateIssueItem[]? Items, bool? Truncated, TemplateIssuePreview? Preview, bool? Deleted);
public sealed record TemplateReportRun(string Name, string OperatorName, int Layer, string Started, string Ended, string Duration, string EndedBy);
public sealed record TemplateReportPage(string Period, string Scope, int Total, int Operators, int WithoutEnd, bool Truncated,
    int Page, int PageCount, TemplateReportRun[] Items);
public sealed record TemplateReportExport(string Html, int Count, int Total, bool Truncated);

public sealed record WeeklyReport(string From, string Through, int TickerPublishes, string TickerLast,
    int UrgentRuns, int UrgentStories, bool NearLimit, string PeakScreen, int PeakPercent, int IdleCount, string[] Idle,
    int[] RepeatCounts, int ChangedCount, string[] Changed, bool Truncated);
public sealed record HandoverActiveLayer(int Layer, string Name);
public sealed record HandoverShow(string Name, int Count, string Last, string Operators);
public sealed record HandoverFailure(string When, string Action, string Name);
public sealed record ShiftHandoverReport(int Hours, bool Truncated, string Connection, int ActiveCount, HandoverActiveLayer[] Active,
    int ShowCount, int HiddenGroups, HandoverShow[] Shows, int RemovalCount, string LastRemoval, int FailureCount, int BlockedCount,
    int NotableCount, HandoverFailure[] RecentFailures, HandoverAcknowledgementView? Acknowledgement = null);
public sealed record HandoverAcknowledgement(string Key, string From, string Through, string RecordedAt);
public sealed record HandoverAcknowledgementView(string? Reference, string From, string Through, HandoverAcknowledgement? Recent);
public sealed record HandoverAcknowledgementCommand(string Reference);

public sealed record OperatorHelpChapter(string Id, string Title, string Detail);
public sealed record OperatorHelpRelease(string Version, string[] Items);
public sealed record OperatorHelp(OperatorHelpChapter[] Chapters, OperatorHelpRelease[] Releases);

public sealed record TelegramAliasTarget(long Id, string Name, string Alias);
public sealed record TelegramAliasReviewCommand(string? Alias);
public sealed record TelegramAliasConfirmCommand(string Review);
public sealed record TelegramAliasPreview(TelegramAliasTarget Target, string Alias, string Review, DateTimeOffset ExpiresAt);
public sealed record TelegramAliasResult(long UserId, string Name, string Alias);

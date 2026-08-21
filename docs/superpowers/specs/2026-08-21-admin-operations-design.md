# Admin operations: external changes, settings, and template registry

## Goal

Make operational changes observable and safe for a Cinegy Air operator:

1. external-change alerts identify the affected bridge template and Cinegy
   state, rather than reporting only a layer number;
2. Settings labels show the unit and a short Arabic explanation; and
3. administrators can read template definitions from Telegram, with optional
   full definition management disabled by default.

## External-change alert

`Update-OnAirStateFromCinegy` will return a structured change record per
removed bridge entry. It retains the existing `Removed` list for callers.
Each record includes: layer, bridge template key, original SHOW user and time,
expected Active ID, Cinegy Active ID/name after the read, output state, and
client identity/connected state.

The watchdog sends one alert containing one block per change. It identifies:

- `القالب الذي كان البوت يعرضه` and layer;
- whether Cinegy reports `مخفي` or `استبدال خارجي`;
- old/new IDs and new Cinegy item name where available;
- Air server and channel;
- the Cinegy client identity when supplied by `/status`.

The API does not expose an origin-program or remote-IP field. The alert must
say `مصدر خارجي غير معرّف` when `ClientIdentity` is absent; it must never
invent an IP address or claim that an identity is a source IP.

## Clear settings

The settings keyboard keeps technical setting names for support but renders a
human-readable value such as `15 ثانية` or `10 ميغابايت`. The prompt opened
for a numeric setting also says its Arabic description, expected unit, current
value, default value, and validation rule.

Units include seconds, minutes, hours, megabytes, files, characters, attempts,
templates, values, and plain counts. Settings without a natural unit retain a
plain numeric value. Boolean and constrained string settings retain their
current controls.

## Template registry administration

### Default mode

`📚 القوالب والإعدادات` is available to administrators. It lists the parsed
template registry and opens a read-only detail view for each template: key,
path, layer, order, description, field names/labels/limits, and preset count.
This is always available, even when full management is disabled.

Existing `⚡ إدارة النصوص الجاهزة` remains unchanged and continues to manage
presets.

### Full management (disabled by default)

`EnableFullTemplateManagement = false` is a protected configuration setting.
Enabling it requires a second confirmation. When enabled, the template detail
view permits a reviewed, wizard-based edit of path, layer, order, description,
and field definitions, plus creation and deletion.

The stable template key is never renamed through Telegram. It is an identifier
used by on-air records, schedules, favorites, drafts, and presets. Deletion is
rejected if the template is currently bridge-tracked on air or referenced by a
future schedule.

### Persistence and validation

All registry writes use one shared save operation:

- parse the current JSON first;
- validate unique key, nonempty path, positive layer, and valid field objects;
- ensure paths resolve within the bridge project directory;
- take a timestamped `templates.json` backup;
- write a temporary JSON file and atomically replace the registry;
- invalidate the template cache only after a successful replacement;
- add an audit entry without template field values.

Every destructive or full-management change has a review screen and explicit
confirmation. A failed validation or write leaves `templates.json` unchanged.

## Tests

Pester coverage will verify:

- an external replacement alert carries the bridge template, old/new Cinegy
  details, Air address, and no invented source IP;
- numeric setting labels and prompts render the right units;
- regular administrators can read templates but cannot invoke full-management
  callbacks while the protected setting is disabled;
- full management rejects invalid paths/layers/fields, protects on-air and
  scheduled templates from deletion, and writes a validated change atomically
  with a backup.

# WinDebloat port — conflicts (second-pass worklist)

> **Resolved 2026-10-19:** maintainer decision — **keep the playbook value for all value/strategy/gating
> conflicts (items 1–9)**; none of those WinDebloat values are ported. The two playbook **bugs (items
> 10–11) were fixed**: `appx.yml` `MixedReality.Portal` → `Microsoft.MixedReality.Portal`, and the no-op
> `Microsoft.Windows.SecureAssessmentBrowser` per-user appx line was removed (it's CBS-removed). The
> detail below is retained for history.


13 conflicts where WinDebloat and the playbook set the **same setting to different values** (or gate it
differently). **None of these were ported** — the playbook's existing value was left untouched. Each
needs a decision. Default recommendation leans toward **keeping the playbook's choice**, because most
playbook omissions/gatings are deliberate regression-avoidance (see
[references-learnings.md](references-learnings.md)). Items marked **DECISION** genuinely depend on user
preference.

Legend: WD = WinDebloat catalog value · PB = playbook value.

## Deliberate playbook choices — recommend keep PB (don't port WD)

1. **`priv.input-personalization-off` · `AllowInputPersonalization`** — WD writes the static policy=0;
   PB applies it via `revitool tweaks personalization input-personalization disable` and `revert.yml`
   *deletes* the static value on upgrade. Porting WD would reintroduce what revert strips. → **Keep PB.**
2. **`priv.usage-reporting-off` · service `DPS`=disabled** — PB deliberately keeps DPS enabled
   (`revert.yml` re-enables it: "needed for the Data Usage page"). → **Keep PB.**
3. **`priv.feature-advert-tips` · `EnableAccountNotifications`** — WD=0, PB=1 (`win-settings.yml:297`,
   deliberate). → **Keep PB** unless you specifically want account notifications off (**DECISION**).
4. **`upd.notification-level` · `SetUpdateNotificationLevel`=2** — WD writes into
   `HKLM\…\Policies\…\WindowsUpdate`, the exact key `revert.yml` deletes on upgrade (WU pause is
   revitool-owned). → **Keep PB** (don't port; it would be wiped).
5. **`game.gamedvr-off` · `AppCaptureEnabled`=0** — WD unconditional; PB gates behind
   `remove-appx-xbox` and reverts when Xbox is kept — **regression #74** (greys out Game Bar recording).
   → **Keep PB gating** (forcing WD risks #74).
6. **`game.gamebar-off` · `ShowStartupPanel`=0** — WD unconditional; PB sets it only under
   `remove-appx-xbox`. → **Keep PB gating** (consistency with Xbox-removal option).

## Strategy divergences — pick one approach

7. **`look.sticky-keys-prompts-off` / `misc.accessibility-hotkeys-off` · Accessibility `Flags`**
   *(reported by two agents — same underlying conflict)* — WD sets specific hotkey-bit-cleared `Flags`
   values (StickyKeys/KeyboardResponse/ToggleKeys/MouseKeys/HighContrast); PB *deletes* those subkeys and
   rewrites every `Flags=0` (accessibility-reset strategy, `control-panel.yml`). Same keys, different data
   and philosophy. → **DECISION:** keep PB's reset-to-0, or adopt WD's targeted hotkey-disable. Don't run
   both. (WD's Narrator `WinEnterLaunchEnabled=0` sub-action was absent and *was* ported.)

## Gating differences — align intent

8. **`shell.cross-device-resume-block`** — identical 3 values, but PB gates them behind
   `remove-appx-yourphone` while WD applies unconditionally. → **DECISION:** gate WD's under the same
   option (recommended, consistent) or make unconditional if you always want Cross-Device Resume off.
9. **`priv.search-cloud-history` / `start.cortana-cloud-search-off` · `AllowCortana`**
   *(reported by two agents — same value)* — WD=0, PB=1 (`search.yml:31`, deliberate). → **DECISION:**
   Cortana is deprecated on current Windows, so PB's `=1` is low-risk; set `=0` only if you want the
   policy explicitly off. The HKCU sibling was left unported with it.

## Playbook bugs to confirm-fix (editing existing files → needs your yes)

10. **`appx.mixed-reality-portal`** — WD removes `Microsoft.MixedReality.Portal`; PB `appx.yml:56` lists
    `MixedReality.Portal` **without the `Microsoft.` prefix** (won't match; correct name is used in
    `deprovisioned-apps.yml`). → **Likely PB typo — confirm to fix** rather than add a duplicate removal.
11. **`appx.secure-assessment-browser`** — WD removes it as per-user appx; PB `appx.yml:16` also lists it,
    but it returns `0x80070032` and is actually stripped at CBS level by `system-components-removal`. The
    appx line is an effective no-op. → **Optional cleanup — confirm.**

## Count reconciliation

13 conflict rows were reported across agents; items 7 and 9 are each reported by two agents for the same
underlying setting, so there are **~11 distinct conflicts**. All are documented above with both values.

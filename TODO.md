## Open
- [ ] test the tray menu (Windows) and the menu bar item (macOS) „Einstellungen“: they now open `/einstellungen` directly
- [ ] remove `server/lib/src/sph/portal_fixes.dart` once liblanis is fixed (issue #3, still open, no reply yet; liblanis 0.1.4 is still the latest, last commit 27 Oct)
- [ ] WebUntis: lessons without a period of the time grid have no period and are not merged into the lessons on Heute (check how often this happens)
- [ ] WebUntis: after the Schulportal adds an entry that WebUntis had supplied, one extra notification is possible
- [ ] WebUntis: check the timetable warning on the real server (Mo „LRS“ is a real difference at the moment)
- [ ] WebUntis: test with a personal student account (may show more than the class account)

## Done
- [x] phone tab bar: „Hausaufgaben“ is shown as „HA“ (was cut off with 8 entries)
- [x] decisions: the name stays Lumo, blue stays the default color scheme, no migration from Gong (never an update path)
- [x] new settings page checked on the real server and the phone
- [x] Proxmox container migrated from Gong to Lumo and updated to 0.15.0
- [x] light/dark switch in the top bar, data age removed from the top bar (0.15.0; works on the phone)
- [x] color scheme Lumo (Indigo) as second option, logout moved to the settings, README screenshots (0.14.0)
- [x] rename to Lumo with the planner-grid icon and the tagline „Dein Schulalltag. Einfach organisiert.“ (0.13.0)
- [x] WebUntis as second source for the timetable, warning on the Stundenplan page on differences (0.12.0)
- [x] settings: floating save entry at the top instead of a full-width bar (0.11.1)
- [x] settings restructured: one page, eight flat groups, one save button, only changed values are saved (0.11.0)
- [x] installed web app reloads itself after a server update (0.10.2; confirmed on the phone with 0.15.0)
- [x] update README files, CLAUDE.md and the plan for Caseda, WebUntis and the installed app
- [x] untis as additional source for the substitution (0.10.0, REST interface of the web app)
- [x] combine Schulportal and WebUntis entries, replaced teacher struck through (0.10.1)
- [x] category filter for rest api (Klausuren, Arbeiten)
- [x] integrate caseda Schulmenü (readable only) (0.9.0)
- [x] Schulessen page with the own orders of the whole week (0.9.2)
- [x] fix Hausaufgaben/Noten/Kurse after the portal changed the teacher list (0.9.1)
- [x] report the changed teacher list to liblanis: https://github.com/lanis-mobile/liblanis/issues/3

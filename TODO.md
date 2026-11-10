## Open
- [ ] migrate the Proxmox container from Gong to Lumo (move `/etc/gong`, `/var/lib/gong` incl. `gong.db`, run the new `install.sh`; steps in the chat / CHANGELOG 0.13.0), then check `/healthz` and the phone app
- [ ] Windows/macOS: install the 0.13.0 apps and rename the old data folders (`gong` → `lumo`)
- [ ] Lumo name: check Google Play and the DPMA register (App Store has „Lumo for Students“)
- [ ] app colors: the web UI is still blue (`#1d5bb8`); adapt accent and `theme_color` to the new indigo icon (`#2b3a8c`)
- [ ] check on the phone that the installed app reloads itself after a release (since 0.10.2; the phone needs one manual restart of the app first) – 0.13.0 is a good test
- [ ] check the new settings page (0.11.0 / 0.11.1) on the real server and the phone: save, unsaved-changes entry at the top, old links (`/einstellungen/server`)
- [ ] test the tray menu (Windows) and the menu bar item (macOS) „Einstellungen“: they now open `/einstellungen` directly
- [ ] remove `server/lib/src/sph/portal_fixes.dart` once liblanis is fixed (issue #3, still open, no reply yet; liblanis 0.1.4 is still the latest, last commit 27 Oct)
- [ ] phone tab bar: with 8 entries „Aufgaben“ is cut off (shorter label?)
- [ ] WebUntis: lessons without a period of the time grid have no period and are not merged into the lessons on Heute (check how often this happens)
- [ ] WebUntis: after the Schulportal adds an entry that WebUntis had supplied, one extra notification is possible
- [ ] WebUntis: check the timetable warning on the real server (update to 0.12.0 or later first) (Mo „LRS“ is a real difference at the moment)
- [ ] WebUntis: test with a personal student account (may show more than the class account)

## Done
- [x] rename to Lumo with the planner-grid icon and the tagline „Dein Schulalltag. Einfach organisiert.“ (0.13.0)
- [x] WebUntis as second source for the timetable, warning on the Stundenplan page on differences (0.12.0)
- [x] settings: floating save entry at the top instead of a full-width bar (0.11.1)
- [x] settings restructured: one page, eight flat groups, one save button, only changed values are saved (0.11.0)
- [x] installed web app reloads itself after a server update (0.10.2)
- [x] update README files, CLAUDE.md and the plan for Caseda, WebUntis and the installed app
- [x] untis as additional source for the substitution (0.10.0, REST interface of the web app)
- [x] combine Schulportal and WebUntis entries, replaced teacher struck through (0.10.1)
- [x] category filter for rest api (Klausuren, Arbeiten)
- [x] integrate caseda Schulmenü (readable only) (0.9.0)
- [x] Schulessen page with the own orders of the whole week (0.9.2)
- [x] fix Hausaufgaben/Noten/Kurse after the portal changed the teacher list (0.9.1)
- [x] report the changed teacher list to liblanis: https://github.com/lanis-mobile/liblanis/issues/3

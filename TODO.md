## Open
- [ ] remove `server/lib/src/sph/portal_fixes.dart` once liblanis is fixed (issue #3, still open, no reply yet)
- [ ] phone tab bar: with 8 entries „Aufgaben“ is cut off (shorter label?)
- [ ] WebUntis: lessons without a period of the time grid have no period and are not merged into the lessons on Heute (check how often this happens)
- [ ] WebUntis: after the Schulportal adds an entry that WebUntis had supplied, one extra notification is possible
- [ ] WebUntis: test with a personal student account (may show more than the class account)

## Done
- [x] untis as additional source for the substitution (0.10.0, REST interface of the web app)
- [x] combine Schulportal and WebUntis entries, replaced teacher struck through (0.10.1)
- [x] category filter for rest api (Klausuren, Arbeiten)
- [x] integrate caseda Schulmenü (readable only) (0.9.0)
- [x] Schulessen page with the own orders of the whole week (0.9.2)
- [x] fix Hausaufgaben/Noten/Kurse after the portal changed the teacher list (0.9.1)
- [x] report the changed teacher list to liblanis: https://github.com/lanis-mobile/liblanis/issues/3

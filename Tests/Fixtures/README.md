# Layout fixtures

Named, persisted workspace states. Each one is a real `layout.json` — the same shape the
app writes to `~/Library/Application Support/ConsoleForge[ Beta]/layout.json`.

**Why these exist.** Every layout bug so far has been *a saved state plus an action*, and
the state was always hand-written as throwaway JSON at the moment of debugging. A fixture
outlives the fix: it is how a bug that was found once stops being findable again.

**Both tiers load these.** Swift unit tests decode them directly
(`Fixture.layout("parked-in-occupied-cell")`); the live harnesses in `scripts/` copy one
into the beta support directory before driving the app. Same file, so a permutation
verified in a unit test and a permutation driven through the real UI cannot drift apart.

**Adding one.** Name it after the SITUATION, not the bug number — `parked-in-occupied-cell`
says what it is to someone who never read the ticket. Keep it minimal: only the slots and
flags the situation needs.

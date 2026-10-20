# Golden traces

`<game>.json` are the golden traces of the mission-parity tests (`tests/trace_<game>_check.tscn`, see
docs/MECHANICS_UNIFICATION.md section 3). They are derived from the game data installed on the machine that
recorded them, and hold hashes only: every row is `[time, event, text, code]` with the time (rounded to the
0.25 s rules tick), the event kind and the numeric code in clear, and the text as the first 12 hex characters of
its sha256. No original mission, voice or script text is stored.

Rows match when event, text hash and code are equal and the time is within one 0.25 s tick. A test writes its golden when the file is missing and otherwise diffs against it; on a difference it prints the
live text next to the golden hash. Goldens are tied to the installed data: re-record (delete the file, run the
test twice to confirm it is stable) when the game data changes.

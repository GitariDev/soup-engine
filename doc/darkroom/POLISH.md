# Polish hill climb

## Contract

The user's brief set the method and is taken as the approved contract. The
judges' scores are the metric, so nothing below is edited once the climb starts.

| Item | Value |
|:--|:--|
| Metric | jury median of the five guidelines, weighted Directness 2, Trust 3, Feel 3, Seeing 2, Buildability 1, out of 10 |
| Direction, target | up, 9.0 with every gate passing |
| Noise | the spread between judges at baseline. A gain counts when it beats that spread |
| Change rule | one change per commit. Before and after evidence in the log. Kept only if better and no gate breaks |
| Guardrails | `sh src/tools/darkroom-gates.sh <samples>`: engine, simulator, Swift tests, print parity, fixture counts, the walk's assertions |
| Scope | `src/darkroom/`, `src/tools/darkroom-*`, `src/tools/mkbench*`, `doc/darkroom/` |
| Holdout | the user's real card, IMG_4230 and IMG_4231, which no judge tunes against |
| Budget | 3 jury rounds and 12 changes |
| Stop | target hit, budget spent, or five changes in a row with no keep |

Judges follow the user's standing rule: Opus at medium up to Fable at extra high,
never lower, at most 3 at a time. Evidence holding the user's photos stays in
`src/out/` or `/tmp`.

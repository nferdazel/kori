# kori documentation

Three documents, all living next to the code they describe.

| File | Holds |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Shape, module boundaries, request path and the reasons behind them. What the README deliberately leaves out. |
| [`DECISIONS.md`](DECISIONS.md) | Decisions already made, with the reasoning, numbered locally. A superseded decision gets a new entry that names it. |
| [`RUNBOOK.md`](RUNBOOK.md) | The operational steps that are not behaviour: branch-and-PR on a protected `main`, tag-after-merge for a permanent release tag, the backup-naming rule and its one-per-process invariant, how to read a smoke-gate rejection, and which `deploy.log` lines are routine. |

The README carries the behaviour contract: the routing classes, the effort table, the log schema and
the HTTP surface. Start there; come here for why.

# Road & Rail Upgrade Brush

Instructions for work in this repository. The terms are in `CONTEXT.md`, the code layout in `ARCHITECTURE.md`, and the checks in `DEVELOPMENT-TOOLS.md`.

## Logs and game output

The user does not read logs. When a task produces a log, Claude MUST read it with tools and report the findings. This covers the game log (`crash_dump\stdout.txt`, path in `DEVELOPMENT-TOOLS.md`), crash dumps, test output, and build output. Claude MUST NOT ask the user to open, search, scan, or paste log lines.

When the log does not exist yet, Claude MUST name the one action that creates it, for example "run the test in the game, then tell me when you are done". The game overwrites `stdout.txt` at every start, so Claude MUST read it right after the user says the test is done.

Test instructions for the user MUST describe only what to do in the game or the tool. They MUST NOT say "read the log".

## Documents

ARCHITECTURE.md MUST hold only structure, constraints, and game facts that the code does not show. It MUST NOT hold progress, test results, build letters, dates, who reported what, or what the next test needs. Progress belongs to the tracker and to git history. A document MUST NOT repeat what the code or its docblocks state, such as caps, constants, function lists, or the text of log lines.

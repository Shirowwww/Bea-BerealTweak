# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

**`AGENTS.md` is the single source of truth and is imported below — put new
guidance there, not here.** Duplicating anything into this file just creates
two copies that drift. It covers, in order: what this project is, the build
commands and what `JAILED=1` actually changes, the architecture and the
per-file rules that go with it (ad blocking, matching BeReal's class names and
localized UI copy, the window-parented button traps), commit conventions, how
to investigate the app by reading a decrypted IPA with `tools/ipa_inspect.py`,
how to build and ship without a Mac, and how to diagnose an "it still doesn't
work" report without burning device-testing rounds.

@AGENTS.md

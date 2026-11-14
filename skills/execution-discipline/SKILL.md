---
name: execution-discipline
description: Rules for executing a plan with subagents so that failures cannot pass unnoticed - one writer at a time, the writer never approves, every test proven by a mutation, the orchestrator verifies in person, escalation one lever at a time, and no agent commits, pushes, deploys or touches production. Use whenever you delegate code changes to subagents, execute a council plan, or the user asks for careful or verified multi-agent execution.
---

# Execution discipline

You are the orchestrator. Agents do the work; you are responsible for knowing whether it was done. An agent's own report is a claim, not evidence.

## The rules

1. **One writer at a time.** Only one agent with edit or write tools runs at any moment. Read-only scouts may run in parallel with each other and with the writer.

2. **The writer never approves.** Every significant delivery goes to the `reviewer` agent, which has no editor and is never the agent that wrote the work. Give it the brief and the diff, not the writer's summary.

3. **Every test is proven with a mutation.** A test that has never failed has not been shown to test anything. For each test a delivery relies on:
   - copy the file under test aside, *inside* the working directory (`cp src/billing.py src/billing.py.mutation-bak`);
   - break the code deliberately in the way the test is meant to catch;
   - run the test and confirm it goes red **for the right reason**: read the failure, don't count it;
   - restore from the copy (`mv src/billing.py.mutation-bak src/billing.py`) and see it green again.

   Restore **from the file copy, never with `git checkout` or `git restore`**: on uncommitted agent work, git restores the last commit and destroys the work. A mutation that does **not** go red is investigated, not filed: either the test is vacuous or the code handles the case better than expected. Find out which.

4. **Verify in person after every agent.** Read the diff yourself (`git diff --stat`, then `git diff`) and run the suite yourself. Exit code 0 with an empty or vague report is apparent success, and that is how a task dies unnoticed. Check that the files the brief named actually changed and that nothing else did.

5. **Escalate one lever at a time.** When an agent fails: first rewrite the brief (most failures are briefs); then raise the effort; only then move to a stronger model. Change one thing per attempt so you learn which mattered. **Two failed attempts and the task goes back to the human**, with what was tried.

6. **No agent commits, pushes, deploys, builds images, or touches production.** Those actions are yours, made with the human's explicit confirmation each time. The plugin's hook refuses the common spellings of these commands inside subagents (git state changes, remote shells, recursive deletes, image builds, deploys); that is a guard rail, not a guarantee, so the rule stays yours.

7. **Every dispatch names its model.** Dispatch the plugin's agents (`plan-council:scout`, `plan-council:worker`, `plan-council:implementer`, `plan-council:reviewer`), whose models are pinned, or pass `model` explicitly. The plugin's hook refuses a dispatch with neither.

## Briefing an executor

A brief is complete when a stranger could do the task without asking. Include: the goal in one sentence; the files to touch and the files *not* to touch; the exact acceptance check (command and expected output); what to do when blocked (stop and report, never improvise). Say which mutation you will use to check its test, so it writes a test that would catch it.

## Things that look like they work and don't

- **A freshly written agent definition is not dispatchable in the session that wrote it.** The agent registry is read when the session starts. Either start a new session, or run it as a child process: `claude -p --agent <name>` if your version supports it, else `claude -p --model <id>` with the agent's instructions as the prompt.
- **Permission modes are not what their names suggest**, and they change between versions. For a non-interactive child executor, the pattern that works is an edit-accepting mode plus an explicit allow-list of the shell commands it needs plus a deny-list of what no agent may do. A mode that "doesn't ask" may simply deny. Check `claude --help` on the installed version, and test the child on a trivial task first.
- **Paths.** Start a child agent from the directory that contains everything it must read, and give it absolute paths. A relative path resolved after a `cd` points at nothing.

## Report to the human

After each task: what changed (files), what you verified yourself (the commands and their results), the reviewer's verdict, mutations run and what each showed, and anything that needs their decision.

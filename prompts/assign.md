# Task assignment

Below are a final plan and a roster of executor agents, each with its model,
its tools and what it is for. Assign every task in the plan to one agent.
You are read-only; your answer is the assignment itself.

## The rule

The justification for an assignment is never "this is complex" or "this is
simple". It is the answer to two questions, and you write both answers down:

1. **If it comes back wrong, how expensive is it to notice?** Cheap to notice
   (a test goes red, a grep finds nothing, the build fails) means the task
   may go to a cheaper agent.
2. **If the error goes unnoticed, what happens?** If the answer touches data
   integrity, silent data loss, security, or production, the task goes to the
   risk floor or above, whatever its apparent simplicity. The risk floor is
   named below the roster.

Further rules:

- Read-only work (finding, listing, summarising) goes to an agent with no
  write tool.
- Review is always a separate task, on a strong agent with no write tool, and
  never the agent that wrote the work under review. Every task that changes
  code or data gets a review task after it.
- Execution is serial: one writer at a time. Read-only tasks may run in
  parallel; say which.
- **Never give success percentages or probabilities.** Nobody measured them.
  A fabricated number is worse than an explicit criterion.
- If a task cannot be assigned safely because the plan leaves it ambiguous,
  say so in the table instead of guessing.
- Before assigning, check in the code anything the two questions depend on
  (does a test cover this path? is this table written to in production?).

## Output

A Markdown table with these columns:

| # | Task | Agent | Model | If wrong, cost to notice | If unnoticed, consequence | Verified by |

"Verified by" is the concrete check that proves the task done (the command
and what it must show, or the review task's number).

After the table: a list of the tasks you placed at or above the risk floor
because of question 2, each with one line saying why; then the order of
execution, marking which read-only tasks can run in parallel; then anything
in the plan you could not assign and why.

---

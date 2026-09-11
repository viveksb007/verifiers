# 02 — bash harness (gsm8k)

Second experiment. Same pipeline as `01-null-harness`, two things changed:

| | 01 (null) | 02 (bash) |
| --- | --- | --- |
| taskset | `reverse_text_v1` | `gsm8k_v1` (math word problems) |
| harness | `null` (one model call, no tools) | `bash` (offers a shell + edit tool, can loop) |
| reward | `lcs` — pure function of the trace | `correct` — runs `verify.py` **in the runtime** |
| extra flag | — | `--env.agent.max-turns 8` caps the tool loop |

Pipeline is identical: docker container → verifiers eval → litellm :4000 → Bedrock (haiku-4-5).

## What actually happened (the interesting part)

Both tasks scored **1.0** (correct). But the bash tool was **offered and never used**.

Each trace is still just 3 nodes — `system → user → assistant` — one model call, no
`tool_calls`. Haiku solved the grade-school math in one shot of text reasoning and
never needed to shell out.

**Lesson: tool availability ≠ tool use.** The harness hands the model a `bash` tool
(the system prompt says so), but the model decides whether to call it. Easy problems →
it just answers.

### Evidence in the trace

- System prompt (harness-injected): *"You are a coding agent. You have access to a
  bash tool… You also have an edit tool…"*
- `prompt_tokens` jumped **40 → 818** vs experiment 01. That extra ~780 tokens is the
  **tool schema** (bash + edit definitions) injected into every request — the harness's
  cost even when the tool goes unused.
- `finish_reason: stop` (not `tool_calls`) — the model ended its turn with a final
  answer, not a tool request.

### What a used tool would look like

If the model *had* called bash, the node graph would grow:

```
[system]
  └─[user]
      └─[assistant  tool_calls=[bash]]      # model requests a command
          └─[tool  (result)]               # runtime runs it, feeds stdout back
              └─[assistant]                # model reads output, answers
```

…and `calls` (model turns) would be > 1. To actually force this, use a task that
*requires* execution (a coding/terminal task) or a harder problem the model can't do
in its head.

## The other real difference: the reward runs in the runtime

`reverse_text`'s reward was pure Python over the trace. `gsm8k`'s `correct` reward
instead writes `verify.py` (with `math-verify`) into the rollout's runtime and
executes it there — so the verifier's dependencies never touch the eval process, and
it grades identically on subprocess / docker / prime runtimes.

That's the two reward shapes in verifiers:
1. **pure trace function** (experiment 01)
2. **runtime read/write/exec** (this one)

## Re-run

```bash
# refresh creds (12h TTL)
eksops creds -i 144465910773 -r Admin | grep '^export' | sed 's/^export //' > /tmp/bedrock.env
echo 'AWS_REGION=us-east-1' >> /tmp/bedrock.env && chmod 600 /tmp/bedrock.env

cd <repo-root>
docker run --rm -v "$PWD":/work -w /work \
  --env-file /tmp/bedrock.env -e LITELLM_KEY=sk-local \
  python:3.12-bookworm bash /work/viveksbh-learn/02-bash-harness/run_eval.sh
```

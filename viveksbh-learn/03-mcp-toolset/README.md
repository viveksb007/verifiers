# 03 — forcing tool use with an MCP toolset (scratchpad)

Experiment 02 offered a `bash` tool but the model never used it (easy math). Here we
pick a taskset that **structurally requires** a tool call, so we can finally see a
multi-turn tool loop in the trace.

## The taskset: `scratchpad_v1`

- The taskset **ships its own tool** — `ScratchpadToolset` (`Taskset.tools`). verifiers
  starts it as an **MCP server** on container loopback and hands its URL to the harness.
- Each task: *"Call `scratchpad_roundtrip` with word=X, then reply with what it returns."*
- The tool stores the word, sleeps 0.5s, reads it back, returns it.
- Reward = 1 **iff** the model's final answer contains its own word.

You **cannot** score without calling the tool — that's the point.

## Result: tool use, 4/4 rollouts, mean reward 1.0 ✅

Every rollout produced the loop we wanted:

```
[system]                         "You are a coding agent… bash tool… "
  └─[user]                       Call scratchpad_roundtrip with word="bravo"…
      └─[assistant  TOOL_CALL]   name=scratchpad_roundtrip  arguments={"word":"bravo"}
          └─[tool  RESULT]       "bravo"        (linked by tool_call_id)
              └─[assistant]      "bravo"        (final answer)
```

5 nodes, **2 model turns** (vs 1 in experiments 01/02). First call ends with
`finish_reason: tool_calls` (not `stop`) — that's the model *requesting* a tool, not
finishing. The runtime runs the tool, appends the `tool` result node, and the model's
second turn reads it and answers.

### The tool-call message shape (what "tool use" actually is on the wire)

Assistant node that requests the tool:
```json
{ "role": "assistant", "content": "",
  "tool_calls": [ { "id": "tooluse_ILP…", "name": "scratchpad_roundtrip",
                    "arguments": "{\"word\": \"bravo\"}" } ] }
```
Tool result node (linked back by `tool_call_id`):
```json
{ "role": "tool", "tool_call_id": "tooluse_ILP…",
  "name": "scratchpad_roundtrip", "content": "bravo" }
```

So a "tool call" is just: assistant message with a `tool_calls` array → a matching
`tool` role message carrying the result. The whole agent loop is that pattern repeated.

## Two bonus concepts this demoed

1. **Toolset → MCP.** First experiment to exercise the tool-server path from the
   architecture docs. The taskset declares `tools = (ScratchpadToolset,)`; verifiers
   runs it as a colocated MCP server and injects the tool into the harness. (The
   harness also still has its own `bash`/`edit` tools — the model just picked the MCP
   one it was told to use.)

2. **Per-rollout state isolation.** One shared server process handled all 4 concurrent
   rollouts, yet each got its *own* word back (bravo / delta / alpha / charlie), never
   crossed — even with a 0.5s sleep between write and read to force an interleave. The
   framework tags each rollout's `self.state` separately. That's the whole reason this
   env exists (it's an isolation test).

## Token note (continuing the thread from 02)

`prompt_tokens = 858` here vs 818 (02) vs 40 (01). The growth is tool schemas injected
into the request — now bash + edit **+ the scratchpad MCP tool**.

## Progression across experiments

| exp | task | tool offered? | tool used? | model turns |
| --- | --- | --- | --- | --- |
| 01 | reverse_text | no (null harness) | — | 1 |
| 02 | gsm8k | yes (bash) | **no** (easy) | 1 |
| 03 | scratchpad | yes (bash + MCP) | **yes** (required) | 2 |

## Re-run

```bash
eksops creds -i 144465910773 -r Admin | grep '^export' | sed 's/^export //' > /tmp/bedrock.env
echo 'AWS_REGION=us-east-1' >> /tmp/bedrock.env && chmod 600 /tmp/bedrock.env

cd <repo-root>
docker run --rm -v "$PWD":/work -w /work \
  --env-file /tmp/bedrock.env -e LITELLM_KEY=sk-local \
  python:3.12-bookworm bash /work/viveksbh-learn/03-mcp-toolset/run_eval.sh
```

# viveksbh-learn — first local eval

Personal sandbox for learning the verifiers v1 system. **Not committed** (see `.gitignore`).
Secrets (AWS creds) live at `/tmp/bedrock.env`, never here.

## What ran

A minimal eval: taskset `reverse_text_v1`, 2 tasks, 1 rollout each, on Claude
`haiku-4-5` via AWS Bedrock.

```
┌─ docker (python:3.12, modern glibc) ───────────────────────────────┐
│  verifiers eval ──HTTP──> litellm :4000 ──SigV4──> AWS Bedrock      │
│  (reverse_text_v1)        (OpenAI /v1 shim)        (us.anthropic    │
│       │                                             .claude-haiku-4-5)│
│       └─ null harness · subprocess runtime · n=2 r=1               │
└─────────────────────────────────────────────────────────────────────┘
```

## Why each choice

| Piece | Reason |
| --- | --- |
| **docker container** | Host is Amazon Linux 2 (glibc 2.26, GCC 7.3). The pinned wheel stack (numpy 2.5, onnxruntime, pyarrow) needs glibc 2.27+; on this host uv falls back to source builds that fail. Container has modern glibc. |
| **litellm proxy** | verifiers only speaks OpenAI-compatible **bearer-key** endpoints (`clients/config.py`). Bedrock uses AWS SigV4 signing, not a bearer key. litellm bridges: OpenAI `/v1` in, SigV4 to Bedrock out. It stands in for what would normally be verifiers' own **interception server**. |
| **`null` harness** | No tool loop — one model call per task. Cleanest trace to read. (Default harness for this taskset is `bash`.) |
| **`subprocess` runtime** | Rollout runs as a local subprocess — no docker-in-docker. (Debug-only per docs; fine here.) |
| **inference profile id** (`us.anthropic...`) | Bare model id `anthropic.claude-haiku-4-5...` rejects on-demand throughput; needs an inference profile ARN/id. |
| **`--no-push`** | Don't upload the run to the Prime Intellect platform. |

## Files

- `litellm.yaml` — maps model name `bedrock-haiku` → `bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0`.
- `run_eval.sh` — runs inside the container: sync deps, start litellm, wait for health, run eval.
- `outputs/first-eval/` — the run artifacts:
  - `config.toml` — the fully-resolved config (every default made explicit). Re-runnable with `eval @ config.toml`.
  - `traces.jsonl` — one **episode** per line (2 tasks → 2 lines).
  - `eval.log` — run + worker logs.

## How to re-run

```bash
# 1. refresh creds (12h TTL), strip 'export ' prefix for docker --env-file
eksops creds -i 144465910773 -r Admin | grep '^export' | sed 's/^export //' > /tmp/bedrock.env
echo 'AWS_REGION=us-east-1' >> /tmp/bedrock.env && chmod 600 /tmp/bedrock.env

# 2. run
cd <repo-root>
docker run --rm -v "$PWD":/work -w /work \
  --env-file /tmp/bedrock.env -e LITELLM_KEY=sk-local \
  python:3.12-bookworm bash /work/viveksbh-learn/run_eval.sh
```

## Reading a trace (the core data model)

Each `traces.jsonl` line is an **Episode** — the global view of one `Env.run`.
`episode.traces` is a list of per-agent **Trace**s (here just 1 — single-agent env).

A `Trace` holds:

- **`nodes`** — the message graph. Each node has a `message` (role+content), a
  `parent` index (linking system → user → assistant), and `sampled: true` on the
  node the model actually produced. `token_ids`/`logprobs`/`mask` are **empty in
  eval** — they're only filled for RL training (via renderers).
- **`calls`** — one `ModelCall` per provider exchange: `model`, `sampling`,
  `endpoint`, `finish_reason`, `usage` (prompt/completion tokens), `time`.
- **`rewards`** — the score. Here `lcs` (longest-common-subsequence ratio of the
  model's reversal vs ground truth), each with a `weight`.
- **`stop_condition`**, `ok`, `errors`, `timing` (boot/setup/generation/finalize/scoring).

### Actual result from this run

| task | model output (assistant node) | lcs reward |
| --- | --- | --- |
| 0 | `<reversed_text>yretemec nwo sti detauguriani ytinutmoc eht 1891 nI</reversed_text>` | 0.931 |
| 1 | (see traces.jsonl) | 0.976 |

Node graph for episode 0:

```
[system]    Reverse the text character-by-character. Put your answer in <reversed_text> tags.
   └─[user]    In 1891 the community inaugurated its own cemetery
        └─[assistant, sampled=true]  <reversed_text> yretemec nwo sti detauguriani ytinutmoc eht 1891 nI </reversed_text>
```

One model call, `finish: stop`, usage `prompt=40 / completion=40`.

The reward function lives on the task (`ReverseTextTask.lcs`, decorated `@vf.reward`)
and runs over the finished trace — pure Python, no runtime needed. That's why
`reverse_text_v1` is the canonical tiny env.

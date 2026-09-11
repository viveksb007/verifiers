#!/usr/bin/env bash
# Runs INSIDE the python:3.12 container (host glibc 2.26 too old for the wheel stack).
# Experiment 03: FORCE tool use via a taskset that ships its own MCP tool.
# scratchpad_v1: reward is 1 ONLY if the model calls the `scratchpad_roundtrip`
# tool and echoes back its own word. Impossible to score without a tool call.
# Also demos the Toolset -> MCP server path (Taskset.tools).
# Pipeline: verifiers eval --HTTP--> litellm :4000 --SigV4--> AWS Bedrock (haiku-4-5).
set -euo pipefail
cd /work

LEARN=/work/viveksbh-learn/03-mcp-toolset

# 1. deps (installs verifiers itself + the scratchpad env from the mounted repo)
pip install -q uv
uv sync --no-default-groups 2>&1 | tail -2
uv pip install -q "litellm[proxy]" boto3 2>&1 | tail -2

# 2. litellm proxy: OpenAI /v1 -> Bedrock (SigV4 from mounted env creds)
uv run litellm --config "$LEARN/litellm.yaml" --port 4000 > "$LEARN/litellm.log" 2>&1 &
LITELLM_PID=$!
trap 'kill $LITELLM_PID 2>/dev/null || true' EXIT

# 3. wait for proxy
for i in $(seq 1 60); do
  curl -sf http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1 && { echo "litellm up"; break; }
  sleep 1
done
curl -sf http://127.0.0.1:4000/health/liveliness >/dev/null || { echo "litellm FAILED"; tail -30 "$LEARN/litellm.log"; exit 1; }

# 4. eval: scratchpad_v1, bash harness (also gets the MCP tool), subprocess runtime.
#    -n 4 -r 1 -> 4 different words; each must round-trip through the tool.
uv run eval scratchpad_v1 \
  --model bedrock-haiku \
  --client.base-url http://127.0.0.1:4000/v1 \
  --client.api-key-var LITELLM_KEY \
  --env.agent.harness.id bash \
  --env.agent.max-turns 6 \
  -n 4 -r 1 \
  --no-push --no-rich \
  -o "$LEARN/outputs/mcp-eval" 2>&1 | tail -50

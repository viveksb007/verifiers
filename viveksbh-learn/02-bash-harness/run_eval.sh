#!/usr/bin/env bash
# Runs INSIDE the python:3.12 container (host glibc 2.26 too old for the wheel stack).
# Experiment 02: BASH harness on gsm8k_v1 — a multi-turn tool loop.
# The agent gets a `bash` tool, can shell out to compute, then answers.
# Pipeline: verifiers eval --HTTP--> litellm :4000 --SigV4--> AWS Bedrock (haiku-4-5).
set -euo pipefail
cd /work

LEARN=/work/viveksbh-learn/02-bash-harness

# 1. deps (installs verifiers itself from the mounted repo /work)
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

# 4. eval: gsm8k_v1, BASH harness (default here, but set explicitly), subprocess runtime.
#    max-turns caps the tool loop so a rollout can't run away.
uv run eval gsm8k_v1 \
  --model bedrock-haiku \
  --client.base-url http://127.0.0.1:4000/v1 \
  --client.api-key-var LITELLM_KEY \
  --env.agent.harness.id bash \
  --env.agent.max-turns 8 \
  -n 2 -r 1 \
  --no-push --no-rich \
  -o "$LEARN/outputs/bash-eval" 2>&1 | tail -50

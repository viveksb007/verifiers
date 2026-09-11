#!/usr/bin/env bash
# Runs INSIDE the python:3.12 container (host glibc 2.26 too old for the wheel stack).
# Pipeline: verifiers eval --HTTP--> litellm :4000 --SigV4--> AWS Bedrock (haiku-4-5).
set -euo pipefail
cd /work

LEARN=/work/viveksbh-learn

# 1. deps
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

# 4. eval: reverse_text_v1, null harness, subprocess runtime, 2 tasks, no push
uv run eval reverse_text_v1 \
  --model bedrock-haiku \
  --client.base-url http://127.0.0.1:4000/v1 \
  --client.api-key-var LITELLM_KEY \
  --env.agent.harness.id null \
  -n 2 -r 1 \
  --no-push --no-rich \
  -o "$LEARN/outputs/first-eval" 2>&1 | tail -40

#!/bin/bash
set -euo pipefail

# Benchmark runner for guidellm >= 0.7.
#
# Usage:
#   ./run.sh                      # run every scenario
#   ./run.sh chat vision          # run only the named scenarios
#   SCENARIOS="chat" ./run.sh     # same, via environment
#
# Any extra guidellm flags can be appended after `--`, e.g.
#   ./run.sh chat -- --constraint kind=max_requests,count=50

if [ -f .env ]; then
    echo "Loading environment variables from .env"
    # shellcheck disable=SC1091
    set -a && source .env && set +a
else
    echo "Warning: .env file not found!"
fi

if [ -z "${BENCH_TARGET:-}" ]; then
    echo "Error: BENCH_TARGET is not set. Cannot run benchmarks." >&2
    exit 1
fi

# --- split args into scenario names and guidellm passthrough flags ----------
cli_scenarios=()
extra_args=()
seen_dashdash=0
for arg in "$@"; do
    if [ "$arg" = "--" ]; then
        seen_dashdash=1
        continue
    fi
    if [ "$seen_dashdash" -eq 1 ]; then
        extra_args+=("$arg")
    else
        cli_scenarios+=("$arg")
    fi
done

# --- resolve the served model id -------------------------------------------
if [ -z "${BENCH_MODEL:-}" ]; then
    echo "BENCH_MODEL unset, querying $BENCH_TARGET/v1/models ..."
    auth_args=()
    [ -n "${BENCH_AUTH_HEADER:-}" ] && auth_args=(-H "Authorization: ${BENCH_AUTH_HEADER}")
    [ -n "${BENCH_API_KEY:-}" ] && auth_args=(-H "Authorization: Bearer ${BENCH_API_KEY}")
    BENCH_MODEL=$(curl -sk --max-time 30 "${auth_args[@]}" "${BENCH_TARGET%/}/v1/models" \
        | uv run python -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null || true)
    if [ -z "$BENCH_MODEL" ]; then
        echo "Error: could not read a model id from $BENCH_TARGET/v1/models." >&2
        echo "       Set BENCH_MODEL in .env explicitly." >&2
        exit 1
    fi
    echo "Detected model: $BENCH_MODEL"
fi

# Tokenizer defaults to the served model id; override when the server reports a
# deployment alias instead of a Hugging Face repo id (e.g. "gemma" -> "google/...").
BENCH_TOKENIZER="${BENCH_TOKENIZER:-$BENCH_MODEL}"

# --- build the shared backend argument string ------------------------------
backend_arg="kind=openai_http,target=${BENCH_TARGET},model=${BENCH_MODEL},verify=${BENCH_VERIFY:-false}"
if [ -n "${BENCH_API_KEY:-}" ]; then
    backend_arg+=",api_key=${BENCH_API_KEY}"
fi
if [ -n "${BENCH_AUTH_HEADER:-}" ]; then
    # Raw (non-Bearer) Authorization header; api_key would prefix "Bearer ".
    backend_arg+=",extras.headers.Authorization=${BENCH_AUTH_HEADER}"
fi

run_label="run=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

sweep_scenarios=(chat rag translation vision)
concurrent_scenarios=(chat_concurrent rag_concurrent translation_concurrent vision_concurrent)

if [ ${#cli_scenarios[@]} -gt 0 ]; then
    selected=("${cli_scenarios[@]}")
elif [ -n "${SCENARIOS:-}" ]; then
    read -r -a selected <<< "$SCENARIOS"
else
    selected=("${sweep_scenarios[@]}" "${concurrent_scenarios[@]}")
fi

mkdir -p results

run_scenario() {
    local name="$1"
    local path="./scenarios/${name}.json"

    if [ ! -f "$path" ]; then
        echo "Error: scenario '$name' not found at $path" >&2
        return 1
    fi

    echo ""
    echo "=== Running scenario: $name (model=$BENCH_MODEL) ==="
    uv run guidellm run \
        --scenario "$path" \
        --backend "$backend_arg" \
        --tokenizer "kind=huggingface_auto,model=${BENCH_TOKENIZER}" \
        --label "scenario=${name}" \
        --label "model=${BENCH_MODEL}" \
        --label "$run_label" \
        --output "kind=json,path=results/${name}.json" \
        --output "kind=csv,path=results/${name}.csv" \
        --output "kind=html,path=results/${name}.html" \
        "${extra_args[@]}"
}

failed=()
for name in "${selected[@]}"; do
    run_scenario "$name" || failed+=("$name")
done

echo ""
if [ ${#failed[@]} -gt 0 ]; then
    echo "Completed with failures: ${failed[*]}"
    exit 1
fi
echo "All benchmarks complete. Results in ./results"

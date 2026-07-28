#!/bin/bash
set -euo pipefail

# Benchmark runner for guidellm >= 0.7.2.
#
# Usage:
#   ./run.sh                      # run every scenario
#   ./run.sh chat vision          # run only the named scenarios
#   SCENARIOS="chat" ./run.sh     # same, via environment
#
# Any extra guidellm flags can be appended after `--`, e.g.
#   ./run.sh chat -- --constraint kind=max_requests,count=50
#
# Resilience knobs (env, all optional):
#   BENCH_HEALTH_PATH     health route relative to BENCH_TARGET (default: health)
#   BENCH_HEALTH_TIMEOUT  seconds to wait for the endpoint to recover (default: 900)
#   BENCH_HEALTH_INTERVAL seconds between health polls (default: 15)
#   BENCH_RETRIES         extra attempts per scenario after a failure (default: 2)
#   BENCH_RETRY_DELAY     seconds to let the server settle before a retry (default: 60)
#   BENCH_SCENARIO_PAUSE  seconds to drain between scenarios (default: 30)

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

BENCH_HEALTH_PATH="${BENCH_HEALTH_PATH:-health}"
BENCH_HEALTH_TIMEOUT="${BENCH_HEALTH_TIMEOUT:-900}"
BENCH_HEALTH_INTERVAL="${BENCH_HEALTH_INTERVAL:-15}"
BENCH_RETRIES="${BENCH_RETRIES:-2}"
BENCH_RETRY_DELAY="${BENCH_RETRY_DELAY:-60}"
BENCH_SCENARIO_PAUSE="${BENCH_SCENARIO_PAUSE:-30}"

# --- shared curl auth arguments --------------------------------------------
auth_args=()
[ -n "${BENCH_AUTH_HEADER:-}" ] && auth_args=(-H "Authorization: ${BENCH_AUTH_HEADER}")
[ -n "${BENCH_API_KEY:-}" ] && auth_args=(-H "Authorization: Bearer ${BENCH_API_KEY}")

health_url="${BENCH_TARGET%/}/${BENCH_HEALTH_PATH#/}"

# Poll the same route guidellm validates against before every worker starts.
# Returns 1 when the endpoint is still unhealthy after BENCH_HEALTH_TIMEOUT.
wait_for_health() {
    local deadline code
    deadline=$(( $(date +%s) + BENCH_HEALTH_TIMEOUT ))

    while :; do
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
            ${auth_args[@]+"${auth_args[@]}"} "$health_url" || echo 000)
        if [ "$code" = "200" ]; then
            return 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "Endpoint still unhealthy (HTTP $code) after ${BENCH_HEALTH_TIMEOUT}s: $health_url" >&2
            return 1
        fi
        echo "Waiting for $health_url to recover (HTTP $code), retrying in ${BENCH_HEALTH_INTERVAL}s ..."
        sleep "$BENCH_HEALTH_INTERVAL"
    done
}

# --- resolve the served model id -------------------------------------------
if [ -z "${BENCH_MODEL:-}" ]; then
    echo "BENCH_MODEL unset, querying $BENCH_TARGET/v1/models ..."
    BENCH_MODEL=$(curl -sk --max-time 30 ${auth_args[@]+"${auth_args[@]}"} "${BENCH_TARGET%/}/v1/models" \
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

invoke_guidellm() {
    local name="$1"
    local path="$2"

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
        --output "kind=plot,path=results/${name}.png,dpi=150" \
        --output "kind=plot,path=results/${name}.svg" \
        ${extra_args[@]+"${extra_args[@]}"}
}

# 0 = success, 1 = scenario failed, 2 = endpoint down (caller aborts the run).
run_scenario() {
    local name="$1"
    local path="./scenarios/${name}.json"
    local attempt=1
    local attempts=$(( BENCH_RETRIES + 1 ))

    if [ ! -f "$path" ]; then
        echo "Error: scenario '$name' not found at $path" >&2
        return 1
    fi

    while :; do
        # A load stage can knock the endpoint over; never start a scenario (or a
        # retry) while it is still returning 503, guidellm would only crash in
        # backend validation and burn the scenario.
        wait_for_health || return 2

        echo ""
        echo "=== Running scenario: $name (model=$BENCH_MODEL, attempt ${attempt}/${attempts}) ==="
        if invoke_guidellm "$name" "$path"; then
            return 0
        fi

        if [ "$attempt" -ge "$attempts" ]; then
            echo "Scenario '$name' failed after ${attempts} attempt(s)." >&2
            return 1
        fi
        attempt=$(( attempt + 1 ))
        echo "Scenario '$name' failed, retrying in ${BENCH_RETRY_DELAY}s ..." >&2
        sleep "$BENCH_RETRY_DELAY"
    done
}

failed=()
skipped=()
aborted=0

for index in "${!selected[@]}"; do
    name="${selected[$index]}"

    if [ "$aborted" -eq 1 ]; then
        skipped+=("$name")
        continue
    fi

    status=0
    run_scenario "$name" || status=$?

    case "$status" in
        0) ;;
        2)
            failed+=("$name")
            aborted=1
            echo "Endpoint did not recover; skipping the remaining scenarios." >&2
            ;;
        *) failed+=("$name") ;;
    esac

    # Let the server drain before the next scenario piles load back on.
    if [ "$aborted" -eq 0 ] && [ "$index" -lt $(( ${#selected[@]} - 1 )) ]; then
        sleep "$BENCH_SCENARIO_PAUSE"
    fi
done

echo ""
if [ ${#skipped[@]} -gt 0 ]; then
    echo "Skipped (endpoint unhealthy): ${skipped[*]}"
fi
if [ ${#failed[@]} -gt 0 ]; then
    echo "Completed with failures: ${failed[*]}"
    exit 1
fi
echo "All benchmarks complete. Results in ./results"

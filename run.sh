#!/bin/bash

if [ -f .env ]; then
    echo "Loading environment variables from .env"
    source .env
else
    echo "Warning: .env file not found!"
fi

if [ -z "$GUIDELLM__OPENAI__BASE_URL" ]; then
    echo "Error: GUIDELLM__OPENAI__BASE_URL is not set. Cannot run benchmarks."
    exit 1
fi

scenarios=("chat.json" "rag.json" "translation.json")
concurrency_rates=(10 50 100 300)
concurrency_scenarios=("chat_concurrent.json" "rag_concurrent.json" "translation_concurrent.json")

echo "Starting standard scenario benchmarks..."

for scenario in "${scenarios[@]}"; do
    echo "Running benchmark for scenario: $scenario"
    uv run --env-file .env guidellm benchmark run \
        --scenario "./scenarios/$scenario" \
        --output-path "results/benchmarks_$scenario.json" \
        --target "$GUIDELLM__OPENAI__BASE_URL"
done

echo "Starting concurrent scenario benchmarks..."

array_length=${#concurrency_scenarios[@]}

for (( i=0; i<array_length; i++ )); do
    concurrency_scenario="${concurrency_scenarios[i]}"
    rate="${concurrency_rates[i]}"

    echo "Running benchmark for concurrent scenario: $concurrency_scenario with rate: $rate"
    uv run --env-file .env guidellm benchmark run \
        --scenario "./scenarios/$concurrency_scenario" \
        --rate "$rate" \
        --output-path "results/benchmarks_$concurrency_scenario_$rate.json" \
        --target "$GUIDELLM__OPENAI__BASE_URL"
done

echo "All benchmarks complete."
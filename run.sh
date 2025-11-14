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

for concurrency_scenario in "${concurrency_scenarios[@]}"; do
    # Remove the .json extension for a cleaner file name prefix
    scenario_prefix="${concurrency_scenario%.json}" 

    for rate in "${concurrency_rates[@]}"; do
        echo "Running benchmark for scenario: $scenario_prefix with rate: $rate"
        output_path="results/benchmarks_${scenario_prefix}_${rate}.json"
        uv run --env-file .env guidellm benchmark run \
            --scenario "./scenarios/$concurrency_scenario" \
            --rate "$rate" \
            --output-path "$output_path" \
            --target "$GUIDELLM__OPENAI__BASE_URL"
    done
done

echo "All benchmarks complete."
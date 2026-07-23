# vllm-benchmark

Load benchmarks for our vLLM deployments, driven by
[guidellm](https://github.com/vllm-project/guidellm) `>= 0.7`.

Covers text workloads (chat, RAG, translation) and a vision workload that sends
real images through `/v1/chat/completions`.

## Setup

```bash
uv sync
cp .env.example .env   # then fill in the values
```

`.env` variables:

| Variable | Purpose |
| --- | --- |
| `BENCH_TARGET` | Base URL of the OpenAI-compatible endpoint, **without** `/v1`. Required. |
| `BENCH_MODEL` | Served model id. Leave empty to auto-detect from `GET /v1/models`. |
| `BENCH_TOKENIZER` | Hugging Face repo id for tokenization. Defaults to `BENCH_MODEL`. Set explicitly when the server reports a deployment alias instead of a repo id. |
| `BENCH_API_KEY` | Sent as `Authorization: Bearer <value>`. |
| `BENCH_AUTH_HEADER` | Sent verbatim as `Authorization: <value>`. Takes precedence over `BENCH_API_KEY`. |
| `BENCH_VERIFY` | Verify the server TLS certificate. `false` for self-signed certs. |
| `HF_TOKEN` | Needed for gated tokenizers such as `google/gemma-*`. |

## Running

```bash
./run.sh                    # every scenario
./run.sh chat vision        # only the named scenarios
SCENARIOS="rag" ./run.sh    # same, via environment

# extra guidellm flags after `--`, useful for a quick dry run
./run.sh chat -- --profile kind=sweep,sweep_size=2 --constraint kind=max_requests,count=20
```

Each scenario writes `results/<scenario>.{json,csv,html}`. The HTML report is
the interactive guidellm UI. Runs are tagged with `scenario`, `model` and a UTC
`run` timestamp label, which land in the reports.

## Scenarios

| Scenario | Data | Profile |
| --- | --- | --- |
| `chat` | synthetic, ~512 in / ~256 out | sweep (10 rates) |
| `rag` | synthetic, ~4096 in / ~512 out | sweep |
| `translation` | synthetic, ~1024 in / ~1024 out | sweep |
| `vision` | `lmms-lab/ChartQA` images + questions | sweep |
| `chat_concurrent` | same as `chat` | concurrent, streams 10/50/100/300 |
| `rag_concurrent` | same as `rag` | concurrent, streams 10/50/100/300 |
| `translation_concurrent` | same as `translation` | concurrent, streams 10/50/100/300 |
| `vision_concurrent` | same as `vision` | concurrent, streams 10/50/100/300 |

The sweep scenarios carry an `over_saturation` constraint in `monitor` mode, so
the report flags the point where the server stops keeping up instead of only
showing degraded latency numbers.

Warmup (10%) and cooldown (5%) phases are excluded from the reported metrics.

## Vision workload

guidellm has no synthetic image generator, so images come from a Hugging Face
dataset. The pipeline is:

1. `data` — `lmms-lab/ChartQA`, streamed (no full download).
2. `data_column_mapper` — `image` → `image_column`, `question` → `text_column`.
3. `data_preprocessors: encode_media` — images resized to `max_size: 896` and
   base64-encoded into the chat message.

`max_size: 896` matches Gemma's vision encoder resolution, so one image maps to
a predictable number of image tokens. Raise or lower it to change the image
token cost per request. The reports gain an **Image Metrics** table with input
pixels and bytes per request.

To swap in a different dataset, the column must be a plain string. Datasets with
list-valued text columns (e.g. `lmms-lab/flickr30k`, whose `caption` is a list of
five strings) fail in the column mapper.

`vision*.json` pin `backend.max_tokens: 256` because a Hugging Face dataset
carries no output-token target, unlike the synthetic scenarios.

## Notes on the 0.7 CLI

Upgrading from 0.3 was a breaking change:

- `guidellm benchmark run` → `guidellm run`.
- Scenario files use a `{"spec": {...}}` schema. `rate_type`/`rate`/`max_requests`/
  `max_seconds` became `profile`/`constraints`.
- Options take `kind=...,key=value` argument strings with dot notation for
  nesting, e.g. `--backend kind=openai_http,extras.headers.Authorization=...`.
- `GUIDELLM__OPENAI__*` environment variables no longer exist; backend settings
  are passed as `--backend` arguments (see `run.sh`).
- Concurrency levels are a list on the profile (`streams: [10, 50, 100, 300]`),
  so one run produces all four sub-benchmarks — no shell loop.
- CLI options are deep-merged into the scenario. You cannot change a profile's
  `kind` from the CLI when the scenario already sets one; the fields of both
  kinds collide. Edit the scenario or use `--override profile.streams 1,2,4`.

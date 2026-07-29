# vllm-benchmark

Load benchmarks for our vLLM deployments, driven by
[guidellm](https://github.com/vllm-project/guidellm) `>= 0.7.2`.

Covers text workloads (chat, RAG, translation) and vision workloads that send
synthetic images through `/v1/chat/completions`.

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

Resilience knobs, all optional (see [When the endpoint falls
over](#when-the-endpoint-falls-over)):

| Variable | Default | Purpose |
| --- | --- | --- |
| `BENCH_HEALTH_PATH` | `health` | Health route, relative to `BENCH_TARGET`. Same route guidellm validates against. |
| `BENCH_HEALTH_TIMEOUT` | `900` | Seconds to wait for the endpoint to come back before giving up on the run. |
| `BENCH_HEALTH_INTERVAL` | `15` | Seconds between health polls. |
| `BENCH_RETRIES` | `2` | Extra attempts per scenario after a failure. |
| `BENCH_RETRY_DELAY` | `60` | Seconds to let the server settle before a retry. |
| `BENCH_SCENARIO_PAUSE` | `30` | Seconds to drain between scenarios. |
| `BENCH_RATE_LIMIT_DELAY` | `60` | Back-off when the health probe answers `429` instead of `5xx`. |
| `BENCH_RESULT_DIR` | `results/<date>_<target>` | Output directory override. |
| `BENCH_VALIDATE_BACKEND` | `false` | Let guidellm health-check the backend from every worker process. |

Behind a request rate limit, `BENCH_VALIDATE_BACKEND=true` is what breaks runs:
guidellm calls `GET /health` from each of its worker processes
(`max_worker_processes`, default 10) at *every* scheduler startup — once per
sweep stage — and a single `429` there aborts the whole worker group with
`Backend validation request failed`. The script's own health gate probes the
same route once per scenario, so the per-worker check is disabled by default.
Cutting `GUIDELLM__MAX_WORKER_PROCESSES` lowers that burst if you need to keep
validation on.

## Running

```bash
./run.sh                    # every scenario
./run.sh chat vision        # only the named scenarios
SCENARIOS="rag" ./run.sh    # same, via environment

# extra guidellm flags after `--`, useful for a quick dry run
./run.sh chat -- --profile kind=sweep,sweep_size=2 --constraint kind=max_requests,count=20
```

Each scenario writes `results/<YYYYMMDD>_<target-slug>/<scenario>.{json,csv,html,png,svg}`,
e.g. `results/20260729_api_kdkp_intranet_bs_ch_kis_gemma4/chat.json`. The
date+target subdir keeps parallel runs (two shells, different `.env`) and
reruns on later days from overwriting each other; override with
`BENCH_RESULT_DIR`. The HTML
report is the interactive guidellm UI; the PNG (150 dpi) and SVG are static
plots of the same benchmark series, handy for slides and PRs. Runs are tagged
with `scenario`, `model` and a UTC `run` timestamp label, which land in the
reports.

Re-export an existing run into another format without re-benchmarking:

```bash
uv run guidellm export results/20260729_api_kdkp_intranet_bs_ch_kis_gemma4/chat.json \
    --output kind=plot,path=results/chat.pdf
```

## Scenarios

| Scenario | Data | Profile |
| --- | --- | --- |
| `chat` | synthetic, ~512 in / ~256 out | sweep (10 rates) |
| `rag` | synthetic, ~4096 in / ~512 out | sweep |
| `translation` | synthetic, ~1024 in / ~1024 out | sweep |
| `vision` | synthetic 896×896 JPEG + ~128 in / ~256 out | sweep |
| `chat_concurrent` | same as `chat` | concurrent, streams 10/50/100/300 |
| `rag_concurrent` | same as `rag` | concurrent, streams 10/50/100/300 |
| `translation_concurrent` | same as `translation` | concurrent, streams 10/50/100/300 |
| `vision_concurrent` | same as `vision` | concurrent, streams 10/50/100/300 |

The sweep scenarios carry an `over_saturation` constraint in `monitor` mode, so
the report flags the point where the server stops keeping up instead of only
showing degraded latency numbers.

Every scenario also carries
`{ "kind": "max_global_error_rate", "rate": 0.05, "minimum": 30, "stopping_scope": "all" }`.
Once 30 requests have been processed and more than 5% of them fail, the current
sub-benchmark stops and — because of `stopping_scope: "all"` — the remaining
rates/streams are skipped instead of grinding through load levels that are
already known to fail. `stopping_scope` works on any constraint; setting
`over_saturation` to `{"mode": "enforce", "stopping_scope": "all"}` would end a
sweep at the saturation point rather than only flagging it.

Warmup (10%) and cooldown (5%) phases are excluded from the reported metrics.

### Concurrency ceilings and ramp-up

The sweep profile's second stage is `throughput`, which by default fires
`max_concurrency: 512` requests at once, at `t=0`. Behind a gateway that is a
connection storm, not a load test — the endpoint answers `503`, every guidellm
worker fails its startup `GET /health`, and the process dies with
`Worker process group startup failed` before writing any output.

So the sweep scenarios pin a lower ceiling: `max_concurrency: 128` for text,
`64` for vision (image requests carry far more bytes and prefill per request).
All scenarios also set `rampup_duration` — 30s for sweeps, 15s for the
concurrent ones — which spreads the initial burst linearly instead of opening
every stream simultaneously.

Raise the ceiling when the deployment can take it; the numbers are the point at
which our gateway broke, not a property of the model.

### When the endpoint falls over

A load stage can knock the endpoint over, and it stays down for longer than the
scenario that caused it. `run.sh` therefore:

1. Polls `BENCH_TARGET/health` before every scenario **and** before every retry,
   so guidellm is never started against a server that is still returning `503`.
2. Retries a failed scenario `BENCH_RETRIES` times, waiting `BENCH_RETRY_DELAY`
   between attempts.
3. Pauses `BENCH_SCENARIO_PAUSE` between scenarios to let the server drain.
4. Aborts the remaining scenarios once the endpoint fails to recover within
   `BENCH_HEALTH_TIMEOUT`, listing them as skipped instead of burning each one
   on the same dead endpoint.

Exit code is 1 when anything failed or was skipped.

## Vision workload

`vision*` scenarios combine two data sources into one request stream — a
`synthetic_text` source for the prompt and output-token target, and a
`synthetic_image` source for the image. No dataset download, no gated repo, and
the image resolution is exact:

```json
{ "kind": "synthetic_image", "width": 896, "height": 896,
  "format": "jpeg", "jpeg_quality": 85, "content": "gradient",
  "images_per_request": 1 }
```

`content` can be `gradient`, `noise`, `solid` or `checkerboard`; `noise`
produces far larger JPEGs, so use it to put wire/decode cost into the picture.
`resolution` (`720p`, `1080p`, …) and `aspect_ratio` (`16:9`) are shorthands for
`width`/`height`. Because the token target comes from the `synthetic_text`
source, these scenarios need no `backend.max_tokens` pin. `synthetic_video` is
available too, for backends that accept video input.

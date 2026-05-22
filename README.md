# whisper-stt-service

Self-hosted Whisper speech-to-text service exposing the **OpenAI-compatible**
`/v1/audio/transcriptions` API. Built on top of
[`fedirz/faster-whisper-server`](https://github.com/fedirz/faster-whisper-server)
and packaged for our consumer fleet (Argo Rollouts, Ambassador, Datadog, ECR).

Default model: **`Systran/faster-whisper-small`** (baked into the image).
Runs entirely on **CPU** — no GPU required.

---

## Endpoints

| Path | Method | Purpose |
|---|---|---|
| `/v1/audio/transcriptions` | POST (multipart) | Transcribe audio → text |
| `/v1/models` | GET | List available models |
| `/health` | GET | Liveness probe |
| `/docs` | GET | OpenAPI / Swagger UI |

Example:
```bash
curl -X POST http://<host>:8000/v1/audio/transcriptions \
  -F "file=@sample.wav" \
  -F "model=Systran/faster-whisper-small" \
  -F "language=en"
```

---

## Local development (Apple Silicon)

The upstream image ships native arm64, so dev uses it directly via compose:

```bash
docker compose up -d            # or: podman compose up -d
curl http://localhost:8000/v1/models
make smoke                      # records mic + transcribes (requires ffmpeg)
```

The custom `Dockerfile` in this repo targets `linux/amd64` for k8s — don't try
to run it natively on Apple Silicon (it will emulate slowly).

---

## Building the image (CI / k8s)

```bash
make docker                # Build:  <ecr>/whisper-stt-service:0.0.1
make docker-push           # Push to ECR
```

The Dockerfile pre-downloads `Systran/faster-whisper-small` at build time so
pods start without a cold-start model download.

---

## Kubernetes layout

Mirrors the rest of the consumer fleet:

```
k8s/
├── deployment.yml             # Jinja2 template (ConfigMap, Service, Rollout,
│                              # Mapping, HPA, optional PVC for model cache)
├── development/vars.yml
├── preprod/vars.yml
├── production/vars.yml
└── loadtest/vars.yml
```

Per-env `vars.yml` keys of interest:

| Key | Meaning |
|---|---|
| `config.persistent_model_cache` | When `true`, mounts a PVC at `~/.cache/huggingface` to survive pod restarts |
| `config.model_cache_size` | PVC size (only used when above is true) |
| `configmap.WHISPER__MODEL` | Override model per env |
| `configmap.WHISPER__COMPUTE_TYPE` | `int8` (recommended for CPU), `float32` (slower, slightly more accurate) |

### Sizing (CPU)

| Env | Replicas | CPU req → lim | Mem req → lim | Model cache |
|---|---|---|---|---|
| development | 1 | 500m → 2000m | 1.5Gi → 3Gi | ephemeral |
| preprod | 2 | 1000m → 3000m | 2Gi → 4Gi | 10Gi PVC |
| production | 2–6 | 1500m → 4000m | 3Gi → 6Gi | 20Gi PVC |
| loadtest | 4–10 | 1000m → 2000m | 2Gi → 3Gi | ephemeral |

The `small` model needs ≈1.5 GB RAM and ~1 CPU core for steady-state inference.
We provision generously to absorb load spikes since CPU transcription is the
slow path. HPA scales out on 70% CPU / 75% memory utilization.

### Expected throughput (CPU, small model)

| Audio length | Approx. latency on 1 vCPU |
|---|---|
| 5 s | ~1.5 s |
| 30 s | ~5–8 s |
| 60 s | ~10–15 s |

Scale `max_replicas` (and the HPA target) based on concurrent request volume.

---

## Environment variables

| Var | Default | Notes |
|---|---|---|
| `WHISPER__MODEL` | `Systran/faster-whisper-small` | Any `Systran/faster-whisper-*` model id |
| `WHISPER__INFERENCE_DEVICE` | `cpu` | Keep as `cpu` |
| `WHISPER__COMPUTE_TYPE` | `int8` | `int8` is the sweet spot for CPU |
| `ENABLE_UI` | `false` | Gradio test UI — leave off in prod; has an arm64 SSE bug anyway |
| `UVICORN_HOST` | `0.0.0.0` | |
| `UVICORN_PORT` | `8000` | |
| `DD_SERVICE` / `DD_ENV` | set by configmap | Datadog tagging |

---

## Smoke test (against running container)

```bash
make run            # build (if needed) and run on :8000
make smoke          # record from mic → transcribe → print result
make logs           # tail server logs
make stop && make clean
```

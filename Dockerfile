# =============================================================================
# Whisper STT Service — CPU image
#
# Builds on top of the proven fedirz/faster-whisper-server runtime and bakes
# the Systran/faster-whisper-small model into the image so pods start fast
# (no first-call download stall in k8s).
#
# Target architecture: linux/amd64 (k8s nodes). For local Apple-Silicon dev
# use docker-compose.yml which pulls the upstream image directly.
# =============================================================================

ARG BASE_IMAGE=docker.io/fedirz/faster-whisper-server:latest-cpu
ARG WHISPER_MODEL=Systran/faster-whisper-small

# ---- stage 1: pre-download the model into HF cache --------------------------
FROM ${BASE_IMAGE} AS modelcache
ARG WHISPER_MODEL
ENV HF_HOME=/opt/hf-cache
RUN mkdir -p /opt/hf-cache && \
    python3 -c "from huggingface_hub import snapshot_download; \
import os; \
snapshot_download(repo_id=os.environ['WHISPER_MODEL'], \
                  local_dir_use_symlinks=False, \
                  cache_dir=os.environ['HF_HOME'])" \
    WHISPER_MODEL=${WHISPER_MODEL}

# ---- stage 2: final runtime image -------------------------------------------
FROM ${BASE_IMAGE}
ARG WHISPER_MODEL

LABEL org.opencontainers.image.title="whisper-stt-service" \
      org.opencontainers.image.description="Self-hosted Whisper speech-to-text (OpenAI-compatible API)" \
      org.opencontainers.image.source="https://github.com/pharmeasy/whisper-stt-service"

# Bake the cached model into the final image
COPY --from=modelcache /opt/hf-cache /root/.cache/huggingface

# Server config (override per-env via k8s configmap)
ENV WHISPER__MODEL=${WHISPER_MODEL} \
    WHISPER__INFERENCE_DEVICE=cpu \
    WHISPER__COMPUTE_TYPE=int8 \
    ENABLE_UI=false \
    UVICORN_HOST=0.0.0.0 \
    UVICORN_PORT=8000

EXPOSE 8000

# Healthcheck for non-k8s runtimes
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS http://localhost:8000/health || exit 1

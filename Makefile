NO_COLOR=\033[0m
OK_COLOR=\033[32;01m
ERROR_COLOR=\033[31;01m
WARN_COLOR=\033[33;01m

include envfile

# Default registry mirrors the rest of the consumer fleet
ECR_REGISTRY ?= 127603365779.dkr.ecr.ap-south-1.amazonaws.com
IMAGE        ?= $(ECR_REGISTRY)/$(APP_NAME)
PLATFORM     ?= linux/amd64
WHISPER_MODEL?= Systran/faster-whisper-small

.PHONY: all docker docker-push run smoke logs stop clean help

all: docker

help:
	@echo "Targets:"
	@echo "  docker        - Build CPU image: $(IMAGE):$(VERSION)"
	@echo "  docker-push   - Push image to ECR"
	@echo "  run           - Run container locally (port 8000)"
	@echo "  smoke         - End-to-end transcription test against localhost:8000"
	@echo "  logs          - Tail container logs"
	@echo "  stop          - Stop and remove the running container"
	@echo "  clean         - Stop container, remove image and model cache volume"

docker:
	@echo "$(OK_COLOR)==> Building CPU image $(IMAGE):$(VERSION) for $(PLATFORM)$(NO_COLOR)"
	@docker buildx build --platform $(PLATFORM) \
		--build-arg WHISPER_MODEL=$(WHISPER_MODEL) \
		--tag $(IMAGE):$(VERSION) \
		--load .

docker-push:
	@echo "$(OK_COLOR)==> Pushing $(IMAGE):$(VERSION)$(NO_COLOR)"
	@aws ecr get-login-password --region ap-south-1 \
		| docker login --username AWS --password-stdin $(ECR_REGISTRY)
	@docker push $(IMAGE):$(VERSION)

run: stop
	@echo "$(OK_COLOR)==> Running $(APP_NAME) on port 8000$(NO_COLOR)"
	@docker run -d --name $(APP_NAME) \
		-p 8000:8000 \
		-v $(APP_NAME)-cache:/root/.cache/huggingface \
		$(IMAGE):$(VERSION)
	@echo "API: http://localhost:8000"
	@echo "Docs: http://localhost:8000/docs"

smoke:
	@echo "$(OK_COLOR)==> Smoke testing transcription endpoint$(NO_COLOR)"
	@which say >/dev/null && say -o /tmp/$(APP_NAME)-smoke.aiff "Hello, this is a smoke test." \
		&& ffmpeg -y -i /tmp/$(APP_NAME)-smoke.aiff -ar 16000 -ac 1 /tmp/$(APP_NAME)-smoke.wav 2>/dev/null \
		|| (echo "Smoke test requires 'say' (macOS) and 'ffmpeg'"; exit 1)
	@curl -sS -X POST http://localhost:8000/v1/audio/transcriptions \
		-F "file=@/tmp/$(APP_NAME)-smoke.wav" \
		-F "model=$(WHISPER_MODEL)" \
		-F "language=en" \
		-w "\nHTTP %{http_code} time=%{time_total}s\n"

logs:
	@docker logs -f $(APP_NAME)

stop:
	@docker rm -f $(APP_NAME) 2>/dev/null || true

clean: stop
	@echo "$(OK_COLOR)==> Removing image and model cache volume$(NO_COLOR)"
	@docker rmi $(IMAGE):$(VERSION) 2>/dev/null || true
	@docker volume rm $(APP_NAME)-cache 2>/dev/null || true

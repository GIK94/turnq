# SPDX-License-Identifier: Apache-2.0
# turnq Makefile. Run `make help` for targets.

SHELL         := /usr/bin/env bash
.DEFAULT_GOAL := help

VERSION   ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT    ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo none)
DATE      ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS   := -s -w -X github.com/turnq/turnq/internal/buildinfo.Version=$(VERSION) \
             -X github.com/turnq/turnq/internal/buildinfo.Commit=$(COMMIT) \
             -X github.com/turnq/turnq/internal/buildinfo.Date=$(DATE)
BIN       := $(CURDIR)/bin
GO        ?= go
GOFLAGS   ?= -trimpath
SEEDS     ?= 200
IMAGE     ?= ghcr.io/turnq/turnq

export CGO_ENABLED := 0
export PATH := $(BIN):$(PATH)

##@ Development

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: tools
tools: ## Install pinned dev tools into ./bin
	GOBIN=$(BIN) $(GO) install github.com/bufbuild/buf/cmd/buf@v1.47.2
	GOBIN=$(BIN) $(GO) install github.com/golangci/golangci-lint/cmd/golangci-lint@v1.62.2
	GOBIN=$(BIN) $(GO) install golang.org/x/vuln/cmd/govulncheck@v1.1.3
	GOBIN=$(BIN) $(GO) install github.com/goreleaser/goreleaser/v2@v2.4.8

.PHONY: dev
dev: build ## Run turnq in dev mode on :7400 (dashboard at /ui)
	$(BIN)/turnq server --dev --data ./.devdata

##@ Build

.PHONY: build
build: dashboard ## Build ./bin/turnq (static)
	$(GO) build $(GOFLAGS) -ldflags '$(LDFLAGS)' -o $(BIN)/turnq ./cmd/turnq

.PHONY: dashboard
dashboard: ## Build the dashboard SPA (embedded into the binary)
	cd web/dashboard && pnpm install --frozen-lockfile && pnpm build

.PHONY: proto
proto: ## Generate code from api/proto
	buf generate

.PHONY: docker
docker: ## Build the Docker image for the host platform
	docker build -f deploy/docker/Dockerfile -t $(IMAGE):$(VERSION) .

##@ Quality

.PHONY: lint
lint: ## Lint Go, protos, dashboard, SDKs
	golangci-lint run ./...
	buf lint
	buf breaking --against '.git#branch=main'
	cd web/dashboard && pnpm lint
	cd sdk/node && pnpm lint
	cd sdk/python && uv run ruff check .

.PHONY: test
test: ## Unit tests (race detector on, shuffled)
	CGO_ENABLED=1 $(GO) test -race -shuffle=on -count=1 ./...
	cd sdk/go && CGO_ENABLED=1 $(GO) test -race ./...

.PHONY: sim
sim: ## Deterministic simulation (SEEDS=N)
	$(GO) test ./internal/sim -run TestSimulation -count=1 -seeds=$(SEEDS) -timeout 60m

.PHONY: integration
integration: build ## Black-box integration + SDK conformance (needs Docker)
	$(GO) test -tags integration -count=1 ./test/integration/...
	$(GO) run ./sdk/conformance/runner --bin $(BIN)/turnq --sdks go,node,python

.PHONY: crash
crash: build ## kill -9 / LazyFS crash loop (linux, needs Docker)
	$(GO) test -tags crash -count=1 -timeout 120m ./test/crash/...

.PHONY: jepsen
jepsen: build ## History-checked workloads under faults
	$(GO) test -tags jepsen -count=1 -timeout 120m ./test/jepsen/...

.PHONY: fuzz
fuzz: ## Short fuzzing pass over decoders/parsers
	$(GO) test ./internal/wal -run=^$$ -fuzz=FuzzRecordDecode -fuzztime=60s
	$(GO) test ./internal/cron -run=^$$ -fuzz=FuzzParse -fuzztime=60s

.PHONY: vuln
vuln: ## govulncheck
	govulncheck ./...

##@ Benchmarks

.PHONY: bench-smoke
bench-smoke: build ## 60s throughput/latency smoke benchmark
	$(GO) run ./bench/harness --scenario bench/scenarios/s1-throughput.yaml --duration 60s --target turnq

.PHONY: bench
bench: build ## Full benchmark suite vs RabbitMQ and BullMQ (needs Docker)
	docker compose -f bench/competitors/docker-compose.yaml up -d
	$(GO) run ./bench/harness --all --out bench/results/$(VERSION)
	docker compose -f bench/competitors/docker-compose.yaml down -v

##@ Release

.PHONY: release-snapshot
release-snapshot: ## Local goreleaser snapshot build
	goreleaser release --snapshot --clean

.PHONY: clean
clean: ## Remove build artifacts
	rm -rf $(BIN)/turnq dist .devdata

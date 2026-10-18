ARG BASE
FROM docker.io/library/golang:1.26.9-alpine@sha256:3082400e369fa24d5fc60bca20edab3f6d604e0c5a690ec66b295eff4dd87ade AS builder
ARG OTEL_TRACE_VERSION=v1.45.0 # renovate: datasource=go depName=go.opentelemetry.io/otel/exporters/otlp/otlptrace
ARG OTEL_TRACE_GRPC_VERSION=v1.45.0 # renovate: datasource=go depName=go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc
ARG OTEL_SDK_VERSION=v1.45.0 # renovate: datasource=go depName=go.opentelemetry.io/otel/sdk
ARG NET_VERSION=v0.60.0 # renovate: datasource=go depName=golang.org/x/net
ARG CRYPTO_VERSION=v0.57.0 # renovate: datasource=go depName=golang.org/x/crypto

WORKDIR /build
ADD https://github.com/elastic/cloud-on-k8s.git#386c7b14f2d1bbb7f2af1e7da997e64875f16e47 .
RUN go get github.com/google/cel-go@v0.29.0 golang.org/x/crypto@${CRYPTO_VERSION} golang.org/x/net@${NET_VERSION} \
      google.golang.org/grpc@v1.83.2 \
      go.opentelemetry.io/otel/exporters/otlp/otlptrace@${OTEL_TRACE_VERSION} \
      go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc@${OTEL_TRACE_GRPC_VERSION} \
      go.opentelemetry.io/otel/sdk@${OTEL_SDK_VERSION} && \
    CGO_ENABLED=0 GOOS=linux go build -mod=readonly -a -o /elastic-operator \
      -ldflags='-X github.com/elastic/cloud-on-k8s/v3/pkg/about.version=3.5.0 -X github.com/elastic/cloud-on-k8s/v3/pkg/about.buildHash=386c7b14 -X github.com/elastic/cloud-on-k8s/v3/pkg/about.buildDate=2026-08-04T08:29:12Z -X github.com/elastic/cloud-on-k8s/v3/pkg/about.buildSnapshot=false' \
      github.com/elastic/cloud-on-k8s/v3/cmd

FROM ${BASE}
COPY --from=builder /elastic-operator /elastic-operator

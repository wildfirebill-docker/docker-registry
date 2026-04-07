FROM golang:1.22-alpine AS builder

WORKDIR /build

RUN apk add --no-cache gcc musl-dev

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=1 GOOS=linux go build -o registry -ldflags="-s -w" .

FROM alpine:3.19

RUN apk add --no-cache \
    ca-certificates \
    tzdata \
    bash \
    curl

RUN adduser -D -u 1000 appuser

WORKDIR /app

COPY --from=builder /build/registry .
COPY --from=builder /build/frontend/index.html ./static/

RUN mkdir -p /data

RUN chown -R appuser:appuser /app /data

USER appuser

EXPOSE 8080

ENV PORT=8080
ENV DB_DRIVER=mysql
ENV DB_SOURCE=root:password@tcp(mariadb:3306)/registry

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/api/v1/health || exit 1

ENTRYPOINT ["/app/registry"]

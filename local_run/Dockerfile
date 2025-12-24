FROM golang:1.24-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    git \
    ca-certificates \
    make \
    gcc \
    musl-dev

WORKDIR /build

# Copy go mod files
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build trivy-db
RUN CGO_ENABLED=1 GOOS=linux go build -a -installsuffix cgo -o trivy-db ./cmd/trivy-db

# Final stage
FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache \
    git \
    ca-certificates \
    bash \
    curl \
    wget \
    tar \
    gzip \
    bzip2 \
    xz \
    tzdata \
    && rm -rf /var/cache/apk/*

WORKDIR /app

# Copy binary from builder
COPY --from=builder /build/trivy-db /app/

# Copy build script
COPY local_run/build-db.sh /app/

# Make scripts executable
RUN chmod +x /app/build-db.sh /app/trivy-db

# Create directories
RUN mkdir -p /cache /output

# Set environment variables
ENV CACHE_DIR=/cache \
    OUTPUT_DIR=/output \
    UPDATE_INTERVAL=24h \
    PATH=/app:$PATH

# Volume for persistent cache (optional)
VOLUME ["/cache", "/output"]

# Health check
HEALTHCHECK --interval=5m --timeout=30s --start-period=30m \
    CMD test -f /output/db/trivy.db || exit 1

# Run the build script
CMD ["/app/build-db.sh"]

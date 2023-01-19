# Build the k6 binary with the extension
FROM docker.io/library/golang:1.18.1 as builder

RUN go install go.k6.io/xk6/cmd/xk6@latest
RUN xk6 build --output /k6 \
  --with github.com/grafana/xk6-output-prometheus-remote@latest \
  --with github.com/mostafa/xk6-kafka@v0.16.0

# Use the operator's base image and override the k6 binary
FROM docker.io/loadimpact/k6:latest
COPY --from=builder /k6 /usr/bin/k6

USER k6

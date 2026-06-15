# Standalone image for the x12tojson converter (also built as a multi-stage
# stage inside airflow/Dockerfile and k8s/Dockerfile).
#   docker build -t x12tojson .
#   docker run --rm -i x12tojson --rule 837p - < claim.x12
FROM golang:1.23-bookworm AS build
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /x12tojson .

FROM gcr.io/distroless/static-debian12
COPY --from=build /x12tojson /usr/local/bin/x12tojson
ENTRYPOINT ["/usr/local/bin/x12tojson"]

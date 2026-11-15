# syntax=docker/dockerfile:1
# The scaler's image: its static Go build, alone on an empty base with the CA
# certificates it needs to reach GitHub. CiRunner.psm1 builds it from this folder, and
# runs it with the distro's Docker socket mounted.

FROM golang:1.27.4 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /scaler .

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /scaler /scaler
ENTRYPOINT ["/scaler"]

FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/addon-template .

FROM alpine:3.22
RUN apk add --no-cache ca-certificates && adduser -D -H -u 10001 addon && mkdir /data && chown addon /data
COPY --from=build /out/addon-template /usr/local/bin/addon-template
USER addon
ENV NEXORA_DATA_DIR=/data
VOLUME /data
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/addon-template"]

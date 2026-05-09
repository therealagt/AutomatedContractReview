FROM golang:1.25 AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/pii-redaction ./main.go

FROM gcr.io/distroless/base-debian12
WORKDIR /
COPY --from=build /out/pii-redaction /pii-redaction

ENV PORT=8080
EXPOSE 8080

ENTRYPOINT ["/pii-redaction"]

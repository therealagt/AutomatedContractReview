FROM golang:1.25 AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /bin/dispatcher ./main.go

FROM gcr.io/distroless/static-debian12:nonroot

ENV PORT=8080
WORKDIR /app
COPY --from=build /bin/dispatcher /app/dispatcher

EXPOSE 8080
CMD ["/app/dispatcher"]

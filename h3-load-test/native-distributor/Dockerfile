FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -o /native-distributor .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /native-distributor /native-distributor
EXPOSE 8080
ENTRYPOINT ["/native-distributor"]

# Pocket Gmail relay — Dart on Cloud Run
FROM dart:3.13 AS build
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get
COPY . .
RUN dart compile exe bin/server.dart -o bin/server

FROM gcr.io/distroless/cc-debian12
WORKDIR /app
COPY --from=build /app/bin/server /app/server
COPY --from=build /app/test/canned-history.json /app/test/canned-history.json
COPY --from=build /app/.gcp/pocket-server-key.json /tmp/key.json
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app/server"]

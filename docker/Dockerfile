# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# Multi-stage build for the SRE challenge SpringBoot apps (front/back/reader).
# Build context = repository root (so the whole Gradle project is available).
#   docker build -f _solution/sre-challenge-monlab/docker/Dockerfile \
#                --build-arg APP=front -t sre-front:<tag> .
# Telemetry agents (OpenTelemetry + Pyroscope) are baked in but only activated
# when the Helm chart sets JAVA_TOOL_OPTIONS / OTEL_* / PYROSCOPE_* env vars.
# ---------------------------------------------------------------------------

# ---- Stage 1: build all three boot jars (layer shared across app images) ----
FROM gradle:8.5-jdk21 AS builder
WORKDIR /home/gradle/src
COPY --chown=gradle:gradle settings.gradle build.gradle gradle.properties ./
COPY --chown=gradle:gradle gradle ./gradle
COPY --chown=gradle:gradle app ./app
RUN --mount=type=cache,target=/home/gradle/.gradle \
    gradle --no-daemon :app:front:bootJar :app:back:bootJar :app:reader:bootJar

# ---- Stage 2: fetch telemetry java agents ----
FROM curlimages/curl:8.11.0 AS agents
WORKDIR /agents
RUN curl -fsSL -o opentelemetry-javaagent.jar \
      https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar \
 && curl -fsSL -o pyroscope.jar \
      https://github.com/grafana/pyroscope-java/releases/latest/download/pyroscope.jar \
 && ls -l /agents

# ---- Stage 3: minimal hardened runtime ----
FROM eclipse-temurin:21-jre AS runtime
ARG APP
LABEL org.opencontainers.image.title="sre-challenge-${APP}" \
      org.opencontainers.image.source="https://github.com/db-demo/sre-challenge" \
      org.opencontainers.image.description="SRE challenge ${APP} service with OTel+Pyroscope agents"
RUN groupadd -g 10001 app && useradd -u 10001 -g app -s /usr/sbin/nologin -M app
COPY --from=agents /agents/ /opt/agents/
COPY --from=builder /home/gradle/src/app/${APP}/build/libs/${APP}-0.1.0.jar /app.jar
USER 10001
# Per README hint; container-aware heap, agents attached via JAVA_TOOL_OPTIONS from the chart.
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-XX:+UseG1GC", \
            "-Djava.security.egd=file:/dev/./urandom", "-jar", "/app.jar"]

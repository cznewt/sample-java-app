# syntax=docker/dockerfile:1.7
# Multi-stage build used by docker-compose for local development.
# (The cluster deployment uses its own image with the OTel/Pyroscope agents.)
#   docker build --build-arg APP=front -t sample-front .
FROM gradle:8.5-jdk21 AS builder
WORKDIR /home/gradle/src
COPY --chown=gradle:gradle settings.gradle build.gradle gradle.properties ./
COPY --chown=gradle:gradle gradle ./gradle
COPY --chown=gradle:gradle app ./app
RUN --mount=type=cache,target=/home/gradle/.gradle \
    gradle --no-daemon :app:front:bootJar :app:back:bootJar :app:reader:bootJar

FROM eclipse-temurin:21-jre AS runtime
ARG APP
RUN groupadd -g 10001 app && useradd -u 10001 -g app -s /usr/sbin/nologin -M app
COPY --from=builder /home/gradle/src/app/${APP}/build/libs/${APP}-0.1.0.jar /app.jar
USER 10001
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-Djava.security.egd=file:/dev/./urandom", "-jar", "/app.jar"]

FROM ibm-semeru-runtimes:open-21-jre

ARG JAR_VERSION=0.1.0
ARG JAR_FILE=./back-${JAR_VERSION}.jar

COPY ${JAR_FILE} /app.jar

ENTRYPOINT ["java", "-Djava.security.egd=file:/dev/./urandom", "-jar", "/app.jar"]

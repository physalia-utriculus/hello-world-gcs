FROM eclipse-temurin:21-jdk-alpine AS build
WORKDIR /app
COPY . .
RUN ./gradlew :app:buildFatJar --no-daemon

FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=build /app/app/build/libs/app-fat.jar app.jar
EXPOSE 8080
ENV PORT=8080
CMD ["java", "-jar", "app.jar"]

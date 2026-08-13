# Build binocular from a sibling checkout (compose sets the build context to
# BINOCULAR_SRC). binocular's own root Dockerfile is stale (its build image
# lacks sbt and it copies a jar name that build.sbt doesn't produce), so the
# working recipe lives here until fixed upstream.
# The image's own sbt is only a launcher: project/build.properties pins the
# real version (sbt 2.0.0 today) and it is downloaded at build time, so the tag
# below does not have to track binocular's sbt/scala.
FROM sbtscala/scala-sbt:eclipse-temurin-21.0.5_11_1.10.7_3.3.4 AS build
WORKDIR /src
COPY . .
RUN sbt assembly
# Find the jar rather than naming its directory. The output path carries both
# the sbt layout and the Scala version (sbt 1: target/scala-3.3.7/, sbt 2:
# target/out/jvm/scala-3.3.8/binocular/), so a hardcoded path breaks on every
# bump of either — and breaks in the FINAL stage, an hour of compilation later.
RUN cp "$(find /src/target -name binocular.jar -print -quit)" /binocular.jar

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /binocular.jar /app/binocular.jar
ENTRYPOINT ["java", "-jar", "/app/binocular.jar"]

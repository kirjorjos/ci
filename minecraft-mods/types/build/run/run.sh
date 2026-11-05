#!/usr/bin/env bash
# One Gradle invocation for every loader in the repository. Nothing is asserted here: the exit
# status of `./gradlew` is the entire verdict, which is what makes this usable by a consumer whose
# only CI need is "it compiles".
set -euo pipefail

: "${TASK:=build}"

./gradlew "$TASK" --no-daemon --console=plain \
  -Dorg.gradle.jvmargs="-Xmx2g -Dfile.encoding=UTF-8" \
  -Dorg.gradle.worker.jvmargs="-Xmx2g"

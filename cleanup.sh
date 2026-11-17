#!/usr/bin/env bash
# Removes what jobs leave in this runner's private dockerd: stopped containers, networks and
# volumes. Service images such as postgres declare VOLUME, so every job leaves an anonymous
# volume behind (~500MB for a test database). Images stay cached.
# Safe to prune everything unused: the dockerd belongs to this runner, which runs one job at
# a time, and this runs only at startup and after a job has finished.
# Best effort: as a job-completed hook, a failure here would fail an otherwise green job.

docker container prune -f >/dev/null || true
docker network prune -f >/dev/null || true
docker volume prune -af >/dev/null || true

Name: why-is-ci-slow
Title: Why is CI so slow?
Description: Containerized CI runs regressed a bit in terms of cache. Can we not get CI as fast as local?
Draft: false
Publish Date: Oct 26, 2024
---
I believe that containerized CI environments helped the industry move forward.
We have easily reproducable environments for testing and allows companies to
stay relatively platform agnostic. But they're often reeeally slow. It's sad
that most CI improvements have been thanks to tools like [bun](https://bun.sh/) or
[uv](https://astral.sh/blog/uv) re-thinking package management from the ground
up with performance at the forefront.

Most CI platforms [are](https://circleci.com/)
[all](https://github.com/features/actions)
[the](https://docs.gitlab.com/runner/) [same](https://buildkite.com/): you
define some YAML-esque file a DAG of containers that run some shell scripts.
These CI platforms can easily run multi-tenant workloads and improve margins
since these container executions are mostly ephemeral. Artifacts are usually
pushed out to an object store like [AWS S3](https://aws.amazon.com/s3/). Most of
them offer a "cache" where they can push and pull from an object store. This is
not really a cache. It's a hack at an attempt to mimic what a cache on local dev
looks like.

So much of CI time is burned:
- Downloading a container, which is often massive to include all necessary tooling.
- Installing dependencies of your project, which is also often also slow.

I wonder why there has not been an attempt (a successful attempt?) of creating a
CI platform that mimics local development environment:
- The git repo is "hot". It'll have the last commit checked out, which will never be that far away from the origin server.
  Pulling down the next branch to test should be small incremenatal delta.
- The filesystem persists: the dependencies are already mostly there (mod new changes).
  Any cached files generated during builds and tests persist.
  There's no slow fetches from an object store.

Of course, a persistent fs allows for bugs to creep up (stale cache not being
invalidated, invalid state not cleaned up, etc.). But this should be the
exception we face, not the default. No developer is blowing their environment
away on every commit. CI shouldn't have to either.

Food for thought.

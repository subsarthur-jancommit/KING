FROM python:3.11-slim

# Pinned exactly, for the same reason every image in this repo is: graphifyy is
# pre-1.0 (0.9.51), and the graph format it writes is what codegraph-serve then
# loads. An unpinned rebuild would change that format under a running server.
#
# The [mcp] extra is what provides `python -m graphify.serve`. Measured on the
# VPS: 26 seconds, 250 MB of site-packages. Deliberately NOT installing [leiden]
# — graspologic/scipy are the largest thing in the dependency tree and community
# clustering is a separate pass this deployment does not run (--no-cluster).
RUN pip install --no-cache-dir "graphifyy[mcp]==0.9.51"

# Non-root, and /out created and chowned HERE rather than left to Docker.
# A named volume mounted onto a path that already exists in the image inherits
# that directory's ownership; mounted onto a path that does not, Docker creates
# it root:root and a non-root process silently cannot write. That second case is
# how omniroute/data lost every API key once already — with zero errors logged.
RUN useradd --create-home --uid 10001 app \
 && mkdir -p /out \
 && chown app:app /out
ENV HOME=/home/app

USER app
WORKDIR /out

# No default CMD. This image has two jobs and each compose service states its
# own, the way agent-sidecar does:
#
#   codegraph-build  graphify extract /src --out /out --code-only --no-cluster
#   codegraph-serve  python -m graphify.serve /out/graphify-out/graph.json \
#                      --transport http --host 0.0.0.0 --port 8130 --path /mcp
#
# Measured on this repo (12,686 tracked files, 10,272 of them extractable):
# the build peaks just over 3 GB and needs 4 GB to finish — at 3 GB the kernel
# OOM-killed it inside its own cgroup — and takes about 4.5 minutes on 2 vCPU.
# It produces an 82 MB graph.json of 58,382 nodes and 163,257 edges.

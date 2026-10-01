# Build and run on native Linux AMD64, not an emulated ARM64 host.
FROM --platform=linux/amd64 ghcr.io/siderolabs/llvm@sha256:251882062d6ce367b3125bf50e64db69e42e09ddc03003d4a37b75c482f46496 AS llvm
FROM --platform=linux/amd64 ghcr.io/siderolabs/tools@sha256:ad7d2319c0c88f81da2a6ed425515ab2898d3054e0dfe63c056eb06133e2722b
COPY --from=llvm / /
WORKDIR /work
# Mount the repository at /input:ro and a private persistent directory at /work.
CMD ["/bin/bash", "/input/kernel/build.sh"]

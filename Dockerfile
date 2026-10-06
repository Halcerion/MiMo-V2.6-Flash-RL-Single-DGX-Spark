# Halcerion MiMo-V2.6-Flash-RL single-Spark kit - container image
# Base matches the Mia/TensorFold proven-on-GB10 pattern: NVIDIA PyTorch with CUDA 13.
# Redistributed as a value-added runtime image; NVIDIA license prints at every start.
FROM nvcr.io/nvidia/pytorch:26.07-py3

# exllamav3 v1.5.2+ is the first stream supporting the MiMo ('mimo2') architecture.
# Required by the benthecarman/MiMo-V2.6-Flash-RL-exl3 pack card.
# TabbyAPI is the reference server for this pack; uvloop is required on aarch64.
ARG EXL3_REF=v1.5.2

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1

# ---------------- Layer 1: exllamav3 source build (aarch64-correct) ----------------
RUN set -eux; \
    git clone --depth 1 --branch "${EXL3_REF}" https://github.com/turboderp-org/exllamav3 /builds/exllamav3; \
    pip install --root-user-action=ignore /builds/exllamav3; \
    pip install --root-user-action=ignore "uvloop>=0.19"

# ---------------- Layer 2: fetch tabbyAPI tree ----------------
# NOTE (verified upstream): TabbyAPI ships NO importable module (py-modules = [])
# and NO requirements.txt. It is a working-tree app: main.py + common/ +
# endpoints/ with in-tree imports; deps live only in pyproject.toml.
# Launch = python3 main.py from the tree root (see tabby-entry.sh).
RUN set -eux; \
    git clone --depth 1 https://github.com/theroyallab/tabbyAPI /builds/tabbyAPI; \
    test -f /builds/tabbyAPI/main.py; \
    test -f /builds/tabbyAPI/pyproject.toml

# ---------------- Layer 3: generate + install tabby deps ----------------
COPY scripts/gen_tabby_deps.py /builds/gen_tabby_deps.py
RUN set -eux; \
    python3 /builds/gen_tabby_deps.py; \
    pip install --root-user-action=ignore -r /builds/tabbyAPI/requirements.generated.txt

# ---------------- Layer 4: verify (build-time truth) ----------------
# exllamav3 version via distribution metadata (module attr is None by design).
# CUDA enforcement lives in the RUNTIME entrypoint, not here: BuildKit build
# containers have no GPU, so a build-time assert would fail healthy builds.
COPY scripts/verify_image.py /builds/verify_image.py
RUN python3 /builds/verify_image.py

# ---------------- Layer 5: stage the tabby tree + entrypoint ----------------
RUN set -eux; \
    mkdir -p /app/tabby; \
    cp -a /builds/tabbyAPI/. /app/tabby/
WORKDIR /app/tabby
COPY tabby-entry.sh /app/tabby/tabby-entry.sh
RUN chmod +x /app/tabby/tabby-entry.sh

# ---------------- Layer 6: POST-stage verify (tree check lives HERE,
# after the copy - Layer 4 previously checked /app/tabby before Layer 5
# staged it: chicken-and-egg ordering bug, caught during flight testing) ------
COPY scripts/verify_stage.py /builds/verify_stage.py
RUN python3 /builds/verify_stage.py

# NVIDIA container toolkit injects GPUs; no --gpus flags inside the image itself.
EXPOSE 8893
ENTRYPOINT ["/app/tabby/tabby-entry.sh"]
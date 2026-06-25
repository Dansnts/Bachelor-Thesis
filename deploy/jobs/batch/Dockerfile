# Image batch = image des workers du RayCluster (ghcr.io/nearai-interreg/ray-sam3).
# Driver et workers partagent cette image, donc jobCore doit y être présent.
FROM nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y \
    python3.12 \
    python3.12-dev \
    python3.12-venv \
    git \
    wget \
    && rm -rf /var/lib/apt/lists/*

RUN python3.12 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app

# PyTorch CUDA 12.6
RUN pip install torch==2.7.0 torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu126

# SAM3
RUN git clone https://github.com/facebookresearch/sam3.git && \
    cd sam3 && \
    pip install ".[notebooks,train,dev]"

COPY jobs/batch/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# coeur commun + pipeline batch
COPY jobs/jobCore /app/jobCore
COPY jobs/batch/main.py /app/main.py
ENV PYTHONPATH=/app

# Utilisateur non-root pour l'exécution.
# Ubuntu 24.04 fournit déjà un utilisateur "ubuntu" en UID 1000 : on le retire
# avant de créer appuser pour éviter le conflit "UID 1000 is not unique".
RUN userdel -r ubuntu 2>/dev/null || true && useradd --create-home --uid 1000 appuser
USER appuser

CMD ["python3.12", "/app/main.py"]

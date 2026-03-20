# Base image : NVIDIA CUDA 12.6 + Python 3.12
FROM nvidia/cuda:12.6.3-cudnn-devel-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1

# Dépendances système + pip via python3.12-venv (évite le conflit avec pip Debian)
RUN apt-get update && apt-get install -y \
    python3.12 \
    python3.12-dev \
    python3.12-venv \
    git \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Crée un environnement virtuel propre dans /opt/venv
RUN python3.12 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /app

# PyTorch 2.7 + CUDA 12.6
RUN pip install torch==2.7.0 torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu126

# SAM3 avec toutes les dépendances nécessaires (notebooks + train)
RUN git clone https://github.com/facebookresearch/sam3.git && \
    cd sam3 && \
    pip install ".[notebooks,train,dev]"

# Le token HF est passé au moment du run uniquement (pas au build)
# docker run --env-file .env ...
COPY test_sam3.py ./

CMD ["python3.12", "test_sam3.py"]

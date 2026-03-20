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

# RAY avec toutes les dépendances nécessaires
RUN pip install "ray[data,train,serve,default]"
RUN pip install datasets huggingface_hub Pillow

COPY wordcount.py ./
COPY dog_classifier.py ./

CMD ["python3.12", "wordcount.py"]

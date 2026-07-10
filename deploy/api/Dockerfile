# Build context = deploy/ (like the job images), so the image can bundle the
# shared jobCore library next to the API code.
FROM python:3.12-slim

WORKDIR /app

COPY api/python/requirements.txt .
RUN pip install --no-cache-dir -r ./requirements.txt

COPY api/python/main.py api/python/index.html ./
COPY jobs/jobCore ./jobCore

# Utilisateur non-root pour l'exécution
RUN useradd --create-home --uid 1000 appuser
USER appuser

CMD ["python", "main.py"]

FROM python:3.12-slim

WORKDIR /app

COPY ./python/requirements.txt .
RUN pip install --no-cache-dir -r ./requirements.txt

COPY ./python/main.py .

# Utilisateur non-root pour l'exécution
RUN useradd --create-home --uid 1000 appuser
USER appuser

CMD ["python", "main.py"]

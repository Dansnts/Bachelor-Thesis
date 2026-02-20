FROM python:3.13-slim

RUN pip install --no-cache-dir \
    "ray[data]" \
    jupyter \
    pyarrow \
    boto3

WORKDIR /app

RUN pip install --no-cache-dir \
    torch torchvision --index-url https://download.pytorch.org/whl/cpu

RUN pip install --no-cache-dir \
    "ray[data]" \
    jupyter

COPY . .

EXPOSE 8888

CMD ["jupyter", "notebook", "--ip=0.0.0.0", "--port=8888", "--no-browser", "--allow-root"]
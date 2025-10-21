FROM python:3.11-slim
WORKDIR /app

# Install nvidia-smi for GPU metrics (optional, only used if GPU available)
RUN apt-get update && apt-get install -y --no-install-recommends \
    procps \
    && rm -rf /var/lib/apt/lists/*

COPY main.py ./
CMD ["python", "main.py"]

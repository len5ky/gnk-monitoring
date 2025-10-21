FROM python:3.11-slim
WORKDIR /app

# Install system dependencies (ping command)
RUN apt-get update && apt-get install -y --no-install-recommends \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml ./
RUN pip install .
COPY . .

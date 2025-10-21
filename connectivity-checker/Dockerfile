FROM python:3.11-slim
WORKDIR /app

# Install system dependencies (ping command)
RUN apt-get update && apt-get install -y --no-install-recommends \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Copy and install the package
COPY pyproject.toml ./
COPY app ./app
RUN pip install --no-cache-dir httpx==0.27.2 pyyaml==6.0.2

# Default command
CMD ["python", "-m", "app.main"]

FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends wireguard-tools iproute2 iptables && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY templates/ templates/
EXPOSE 5000
CMD ["gunicorn", "-b", "0.0.0.0:5080", "--workers", "1", "--timeout", "30", "app:app"]

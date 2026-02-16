# Load-test participant image: runs participant.py (Matrix + LiveKit, synthetic A/V + text).
# Used when running participants in k8s (--k8s-participants).
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY scripts/ scripts/
# So participant can import fake_media
ENV PYTHONPATH=/app/scripts

# Default: run participant (override in Job with args)
ENTRYPOINT ["python3", "/app/scripts/participant.py"]

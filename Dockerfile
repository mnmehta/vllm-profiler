FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    WEBHOOK_PORT=8443

WORKDIR /app
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

COPY webhook.py /app/

EXPOSE 8443
CMD ["python", "/app/webhook.py"]



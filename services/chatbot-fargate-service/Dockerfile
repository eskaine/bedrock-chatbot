FROM python:3.11-slim

WORKDIR /app

COPY chatbot-fargate-service/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY shared/ shared/
COPY chatbot-fargate-service/src/ .

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]

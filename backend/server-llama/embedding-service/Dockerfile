FROM python:3.10-slim

WORKDIR /app

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Expose the port the app runs on
EXPOSE 8001

# Command to run the application
CMD ["uvicorn", "embeddings_service:app", "--host", "0.0.0.0", "--port", "8001"]
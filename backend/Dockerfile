FROM python:3.11.13-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt requirements-lock.txt ./
RUN pip install --no-cache-dir -r requirements.txt -c requirements-lock.txt && useradd --uid 10001 --create-home nutrition
COPY app ./app
COPY migrations ./migrations
RUN mkdir /data && chown nutrition:nutrition /data
USER nutrition
ENV NUTRITION_DATABASE=/data/nutrition.sqlite3
EXPOSE 8000
CMD ["uvicorn","app.asgi:app","--host","0.0.0.0","--port","8000","--no-access-log","--proxy-headers","--forwarded-allow-ips=172.28.0.2"]

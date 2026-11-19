FROM python:3.12-slim
WORKDIR /app
COPY app.py .
COPY static ./static
ENV OPENUP_DATA=/data OPENUP_PORT=7777 PYTHONUNBUFFERED=1
VOLUME /data
EXPOSE 7777
HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:7777/health')"
CMD ["python", "app.py"]

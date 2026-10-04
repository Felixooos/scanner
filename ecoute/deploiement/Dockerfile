FROM python:3.12-slim
RUN pip install --no-cache-dir "aiohttp>=3.9"
WORKDIR /app
# le contexte de build est le dossier ecoute/ (voir docker-compose.yml)
COPY relais.py page.html ./
CMD ["python", "relais.py"]

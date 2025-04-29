FROM python:3.9-slim

# Install system deps for MoviePy (FFmpeg, etc.)
RUN apt-get update \
  && apt-get install -y ffmpeg libsm6 libxext6 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Python deps
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Your render script
COPY render_daily_video.py .

USER 1000

ENTRYPOINT ["python", "render_daily_video.py"]

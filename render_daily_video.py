# render_daily_video.py

import os
import io
import json
import boto3
import openai
from openai.error import RateLimitError
from datetime import datetime
from moviepy.editor import (
    TextClip,
    ColorClip,
    CompositeVideoClip,
    AudioFileClip,
    concatenate_videoclips
)

# ─── CONFIG ────────────────────────────────────────────────────────
OPENAI_API_KEY  = os.environ['OPENAI_API_KEY']
AWS_REGION      = 'eu-north-1'
S3_BUCKET       = 'my-daily-videos-bucket-2025-umar'
VIDEO_DURATION  = 60           # seconds per slide
POLLY_VOICE     = 'Maja'
TMP_DIR         = '/tmp'
OUTPUT_FILENAME = datetime.utcnow().strftime('%Y-%m-%d') + '.mp4'
# ───────────────────────────────────────────────────────────────────

# 1. Generate today’s script with OpenAI (with fallback)
openai.api_key = OPENAI_API_KEY
prompt = (
    "Write a concise 3-5 minute script (in bullet points) for a YouTube video on "
    f"today’s most interesting topic. Title the script and provide ~5 bullets."
)

try:
    resp = openai.ChatCompletion.create(
        model="gpt-4o-mini",
        messages=[{"role": "user", "content": prompt}],
        temperature=0.7,
    )
except RateLimitError:
    print("⚠️ Rate limit hit on gpt-4o-mini; falling back to gpt-3.5-turbo")
    resp = openai.ChatCompletion.create(
        model="gpt-3.5-turbo",
        messages=[{"role": "user", "content": prompt}],
        temperature=0.7,
    )

content = resp.choices[0].message.content.strip()

# Split into title + bullets
lines = [l.strip("– ") for l in content.splitlines() if l.strip()]
title = lines[0]
bullets = lines[1:]

# 2. Synthesize with AWS Polly
polly = boto3.client('polly', region_name=AWS_REGION)
script_text = "\n".join(bullets)
tts = polly.synthesize_speech(
    Text=script_text,
    OutputFormat='mp3',
    VoiceId=POLLY_VOICE,
    Engine='neural'
)
audio_path = os.path.join(TMP_DIR, "narration.mp3")
with open(audio_path, 'wb') as f:
    f.write(tts['AudioStream'].read())

# 3. Build video clips
clips = []

# 3a. Title card
title_txt = TextClip(title, fontsize=70, color='white', size=(1280,720), method='caption')
title_bg  = ColorClip((1280,720), col=(30,30,30)).set_duration(5)
clips.append(CompositeVideoClip([title_bg, title_txt.set_pos('center')]))

# 3b. One slide per bullet
for b in bullets:
    txt = TextClip(b, fontsize=50, color='white', size=(1280,720), method='caption')
    bg  = ColorClip((1280,720), col=(20,20,60)).set_duration(VIDEO_DURATION)
    clips.append(CompositeVideoClip([bg, txt.set_pos('center')]))

# 4. Attach narration
audio = AudioFileClip(audio_path)
video = concatenate_videoclips(clips)
video = video.set_audio(audio).subclip(0, min(video.duration, audio.duration))

# 5. Write out the file
output_path = os.path.join(TMP_DIR, OUTPUT_FILENAME)
video.write_videofile(output_path, fps=24, codec='libx264')

# 6. Upload to S3
s3 = boto3.client('s3', region_name=AWS_REGION)
s3.upload_file(output_path, S3_BUCKET, OUTPUT_FILENAME,
               ExtraArgs={'ContentType': 'video/mp4'})

print("Rendered and uploaded:", OUTPUT_FILENAME)
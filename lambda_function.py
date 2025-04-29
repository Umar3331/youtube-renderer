import json
import io
import boto3
from datetime import datetime
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseUpload

# ─── CONFIG ──────────────────────────────────────────────────────────────
# Update these to your actual names:
S3_BUCKET   = 'my-daily-videos-bucket-2025-umar'
SECRET_NAME = 'prod/YouTubeUploader/credentials'
# ───────────────────────────────────────────────────────────────────────────

def lambda_handler(event, context):
    # 1. Load YouTube OAuth credentials from Secrets Manager
    sm        = boto3.client('secretsmanager')
    secret    = sm.get_secret_value(SecretId=SECRET_NAME)
    creds_data= json.loads(secret['SecretString'])
    creds = Credentials(
        None,
        refresh_token = creds_data['refresh_token'],
        client_id     = creds_data['client_id'],
        client_secret = creds_data['client_secret'],
        token_uri     = creds_data['token_uri']
    )

    # 2. Determine which S3 key to upload
    #    If the test event passes {"key":"foo.mp4"} it uses that,
    #    otherwise it picks today's date (UTC) as YYYY-MM-DD.mp4
    key = event.get('key') or datetime.utcnow().strftime('%Y-%m-%d') + '.mp4'

    # 3. Fetch the video from S3 into memory
    s3  = boto3.client('s3')
    obj = s3.get_object(Bucket=S3_BUCKET, Key=key)
    data = obj['Body'].read()
    bio  = io.BytesIO(data)

    # 4. Build YouTube service and prepare upload
    youtube = build('youtube', 'v3', credentials=creds)
    media   = MediaIoBaseUpload(bio, mimetype='video/mp4', chunksize=-1, resumable=True)
    request = youtube.videos().insert(
        part='snippet,status',
        body={
            'snippet': {
                'title':       f'Daily Video — {key.replace(".mp4","")}',
                'description': 'Automated daily upload via AWS Lambda',
                'tags':        ['daily','automation'],
                'categoryId':  '22'
            },
            'status': {'privacyStatus': 'public'}
        },
        media_body=media
    )

    # 5. Execute the upload, streaming in chunks
    response = None
    while response is None:
        status, response = request.next_chunk()
        if status:
            print(f"Upload progress: {int(status.progress() * 100)}%")

    video_id = response.get('id')
    print(f"Upload complete. Video ID: {video_id}")

    # 6. Return the new Video ID
    return {
        'statusCode': 200,
        'body': json.dumps({'videoId': video_id})
    }
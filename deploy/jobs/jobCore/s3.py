import os


def make_s3_client():
    import boto3
    import urllib3
    from botocore.client import Config

    # MinIO uses a self-signed certificate, so we connect with verify=False.
    # Silence the per-request InsecureRequestWarning that would flood the logs.
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    return boto3.session.Session().client(
        service_name="s3",
        endpoint_url=os.getenv("S3_ENDPOINT_URL"),
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY_ID")
        or os.getenv(
            "AWS_ACCESS_KEY"
        ),  # accept both AWS_ACCESS_KEY and AWS_ACCESS_KEY_ID so we don't depend on the variable name.
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        config=Config(connect_timeout=5, read_timeout=30, retries={"max_attempts": 3}),
        verify=False,
    )

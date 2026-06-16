import os


def make_s3_client():
    import boto3
    from botocore.client import Config

    return boto3.session.Session().client(
        service_name="s3",
        endpoint_url=os.getenv("S3_ENDPOINT_URL"),
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY_ID")
        or os.getenv(
            "AWS_ACCESS_KEY"
        ),  # on accepte AWS_ACCESS_KEY et AWS_ACCESS_KEY_ID pour ne pas dépendre du nom de la variable.
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        config=Config(connect_timeout=5, read_timeout=30, retries={"max_attempts": 3}),
        verify=False,
    )
